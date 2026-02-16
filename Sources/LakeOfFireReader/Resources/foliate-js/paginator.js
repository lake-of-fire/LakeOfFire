// TODO: "prevent spread" for column mode: https://github.com/johnfactotum/foliate-js/commit/b7ff640943449e924da11abc9efa2ce6b0fead6d

const CSS_DEFAULTS = {
    gapPct: 5,
    minGapPx: 36,
    topMarginPx: 0, //4,
    bottomMarginPx: 69,
    sideMarginPx: 32,
    maxInlineSizePx: 720,
    maxBlockSizePx: 1440,
    maxColumnCount: 2,
    maxColumnCountPortrait: 1,
};

// Chevron visual animations toggle (restored to enabled)
const CHEVRON_VISUALS_ENABLED = true;
// Preview chevrons during a swipe before navigation triggers
// Set to false to avoid mid-gesture state that previously required resets.
const CHEVRON_SWIPE_PREVIEW_ENABLED = false;

const logBug = globalThis.logBug || (() => {});

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
const MANABI_TRACKING_SIZE_BAKED_ATTR = 'data-manabi-size-baked'
// Geometry bake disabled: keep constants for compatibility, but no-op the workflow below.
const MANABI_TRACKING_SIZE_BAKE_ENABLED = true
// Foliate upstream inserts lead/trail sentinel pages in paginated mode; keep adjustment on.
const MANABI_RENDERER_SENTINEL_ADJUST_ENABLED = true
const MANABI_TRACKING_SIZE_BAKE_BATCH_SIZE = 5
const MANABI_TRACKING_SIZE_BAKING_OPTIMIZED = true
const MANABI_TRACKING_SIZE_RESIZE_TRIGGERS_ENABLED = true
const MANABI_TRACKING_SIZE_BAKING_BODY_CLASS = 'manabi-tracking-size-baking'
const MANABI_TRACKING_FORCE_VISIBLE_CLASS = 'manabi-tracking-force-visible'
const MANABI_TRACKING_SECTION_BAKING_CLASS = 'manabi-tracking-section-baking'
const MANABI_TRACKING_SECTION_HIDDEN_CLASS = 'manabi-tracking-section-hidden'
const MANABI_TRACKING_SECTION_BAKED_CLASS = 'manabi-tracking-section-baked'
const MANABI_TRACKING_SECTION_BAKE_SKIPPED_CLASS = 'manabi-tracking-section-bake-skipped'
const MANABI_TRACKING_SIZE_BAKE_STYLE_ID = 'manabi-tracking-size-bake-style'
const MANABI_TRACKING_SIZE_STABLE_MAX_EVENTS = 120
const MANABI_TRACKING_SIZE_STABLE_REQUIRED_STREAK = 2
const MANABI_TRACKING_DOC_STABLE_MAX_EVENTS = 180
const MANABI_TRACKING_DOC_STABLE_REQUIRED_STREAK = 2
const MANABI_TRACKING_CACHE_HANDLER = globalThis.MANABI_TRACKING_CACHE_HANDLER || 'trackingSizeCache'
globalThis.MANABI_TRACKING_CACHE_HANDLER = MANABI_TRACKING_CACHE_HANDLER
const MANABI_TRACKING_CACHE_VERSION = 'v1'
const MANABI_SENTINEL_ROOT_MARGIN_PX = 64

const trackingSizeCacheResolvers = new Map()
let trackingSizeCacheRequestCounter = 0

// General logger disabled for noise reduction
const logEBook = () => {}

// Focused pagination diagnostics for tricky resume/relocate cases.
// pagination logger disabled for noise reduction
const logEBookPagination = () => {}

// Perf logger for targeted instrumentation (disabled)
const logEBookPerf = (event, detail = {}) => ({ event, ...detail })

// Targeted resize diagnostics (off by default unless called explicitly)
const logEBookResize = (event, detail = {}) => {
    try {
        const payload = { event, ...detail }
        const line = `# EBOOK RESIZE ${JSON.stringify(payload)}`
        globalThis.window?.webkit?.messageHandlers?.print?.postMessage?.(line)
    } catch (error) {
        try {
            console.log('# EBOOK RESIZE fallback', event, detail, error)
        } catch (_) {}
    }
}

// Visual flash/visibility diagnostics
const logEBookFlash = (event, detail = {}) => {
    try {
        const payload = { event, ...detail }
        const line = `# EBOOKFLASH ${JSON.stringify(payload)}`
        globalThis.window?.webkit?.messageHandlers?.print?.postMessage?.(line)
    } catch (error) {
        try {
            console.log('# EBOOKFLASH fallback', event, detail, error)
        } catch (_) {}
    }
}

// Explicit bake diagnostics (user-requested) with tight budget to avoid log spam.
let logEBookBakeCounter = 0
const LOG_EBOOK_BAKE_LIMIT = 400
const logEBookBake = (event, detail = {}) => {
    if (logEBookBakeCounter >= LOG_EBOOK_BAKE_LIMIT) return
    logEBookBakeCounter += 1
    try {
        const payload = { event, ...detail }
        const line = `# EBOOKBAKE ${JSON.stringify(payload)}`
        globalThis.window?.webkit?.messageHandlers?.print?.postMessage?.(line)
    } catch (error) {
        try {
            console.log('# EBOOKBAKE fallback', event, detail, error)
        } catch (_) {}
    }
}

// Default whitelist keeps logs focused; set global `manabiPageNumVerbose = true`
// to re‑enable all pagination geometry noise when debugging.
const MANABI_PAGE_NUM_WHITELIST = new Set([
    // Core pagination signals
    'nav:set-page-targets',
    'nav:total-pages-source',
    'nav:page-metrics',
    'relocate',
    'relocate:label',
    'relocate:detail',
    'afterScroll:metrics',
    // Bake/cache checkpoints (still useful but low volume)
    'bake:reset-state',
    'bake:reveal-prebake-content',
    'cache:apply',
    'cache:container-apply',
    'tracking-size-skip-writing-mode',
    // Paging outcomes (omit per-frame size churn)
    'pages',
    'size:anomaly',
]);

const logEBookPageNum = (event, detail = {}) => {
    try {
        const verbose = !!globalThis.manabiPageNumVerbose;
        const allow = verbose || MANABI_PAGE_NUM_WHITELIST.has(event);
        if (!allow) return;
        const payload = { event, ...detail };
        const line = `# EBOOKK PAGENUM ${JSON.stringify(payload)}`;
        globalThis.window?.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (error) {
        try {
            console.log('# EBOOKK PAGENUM fallback', event, detail, error)
        } catch (_) {}
    }
}

let logEBookPageNumCounter = 0
const LOG_EBOOK_PAGE_NUM_LIMIT = 1200
const logEBookPageNumLimited = (event, detail = {}) => {
    if (logEBookPageNumCounter >= LOG_EBOOK_PAGE_NUM_LIMIT) return
    logEBookPageNumCounter += 1
    logEBookPageNum(event, { count: logEBookPageNumCounter, ...detail })
}

const applyVerticalWritingClass = (doc, isVertical) => {
    const enable = !!isVertical
    try { doc?.body?.classList?.toggle('reader-vertical-writing', enable) } catch (_) {}
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
    const beforeRect = target.getBoundingClientRect?.()
    target.classList.add(MANABI_TRACKING_PREBAKE_HIDDEN_CLASS)
    target.style.setProperty('display', 'none', 'important')
    const afterRect = target.getBoundingClientRect?.()
    logEBookFlash('prebake-hide', {
        url: doc?.URL || null,
        targetId: target.id || null,
        beforeRect: beforeRect ? {
            width: Math.round(beforeRect.width),
            height: Math.round(beforeRect.height),
        } : null,
        afterRect: afterRect ? {
            width: Math.round(afterRect.width),
            height: Math.round(afterRect.height),
        } : null,
    })
    logEBookPageNumLimited('bake:hide-doc', {
        url: doc?.URL || null,
        targetId: target.id || null,
        beforeRect: beforeRect ? {
            width: Math.round(beforeRect.width),
            height: Math.round(beforeRect.height),
        } : null,
        afterRect: afterRect ? {
            width: Math.round(afterRect.width),
            height: Math.round(afterRect.height),
        } : null,
    })
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
    const beforeRect = target?.getBoundingClientRect?.()
    if (target instanceof HTMLElement) {
        target.classList.remove(MANABI_TRACKING_PREBAKE_HIDDEN_CLASS)
        restoreInlineStyleProperty(target, 'display', snapshot)
    }
    const afterRect = target?.getBoundingClientRect?.()
    logEBookFlash('prebake-reveal', {
        url: doc?.URL || null,
        targetId: target?.id || null,
        beforeRect: beforeRect ? {
            width: Math.round(beforeRect.width),
            height: Math.round(beforeRect.height),
        } : null,
        afterRect: afterRect ? {
            width: Math.round(afterRect.width),
            height: Math.round(afterRect.height),
        } : null,
    })
    logEBookPageNumLimited('bake:reveal-doc', {
        url: doc?.URL || null,
        targetId: target?.id || null,
        beforeRect: beforeRect ? {
            width: Math.round(beforeRect.width),
            height: Math.round(beforeRect.height),
        } : null,
        afterRect: afterRect ? {
            width: Math.round(afterRect.width),
            height: Math.round(afterRect.height),
        } : null,
    })
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
${MANABI_TRACKING_SECTION_SELECTOR}.${MANABI_TRACKING_SECTION_BAKED_CLASS},
${MANABI_TRACKING_SECTION_SELECTOR}.${MANABI_TRACKING_SECTION_BAKE_SKIPPED_CLASS} { contain: layout style !important; }
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

const measureSectionSizes = (el, vertical, preMeasuredRects) => {
    logEBookPerf('RECT.before-measure', {
        id: el?.id || null,
        baked: el?.hasAttribute?.(MANABI_TRACKING_SIZE_BAKED_ATTR) || false,
    })
    const id = el?.id
    const preRects = preMeasuredRects?.get(id)
    // If we already baked or captured this element in the batch map, avoid any fresh DOM reads.
    if (preMeasuredRects && (el?.hasAttribute?.(MANABI_TRACKING_SIZE_BAKED_ATTR) || preRects)) {
        if (!preRects || preRects.length === 0) return null
        return summarizeRects(preRects, vertical)
    }

    const rects = Array.from(el.getClientRects?.() ?? []).filter(r => r && (r.width || r.height))
    if (rects.length === 0) return null

    // Column gap (px); fall back to 0 if unavailable
    let gap = 0
    try {
        const cs = el.ownerDocument?.defaultView?.getComputedStyle?.(el)
        gap = parseFloat(cs?.columnGap) || 0
    } catch {}

    return summarizeRects(rects, vertical, gap)
}

const summarizeRects = (rects, vertical, gap = 0) => {
    // Axis-aware aggregation:
    // Horizontal writing: inline = max column width; block = sum of column heights + gaps.
    // Vertical writing:   inline = max column height; block = sum of column widths + gaps.
    const inlineLengths = rects.map(r => vertical ? r.height : r.width)
    const blockLengths = rects.map(r => vertical ? r.width : r.height)
    const inlineSize = Math.max(...inlineLengths)
    const blockSize = blockLengths.reduce((acc, v) => acc + v, 0) + gap * Math.max(0, rects.length - 1)

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

    if (MANABI_TRACKING_SIZE_BAKE_ENABLED) ensureTrackingSizeBakeStyles(doc)

    // Wait for fonts to settle to reduce post-bake growth
    try { await doc.fonts?.ready } catch {}

    const sections = Array.from(doc.querySelectorAll(MANABI_TRACKING_SECTION_SELECTOR))
    if (sections.length === 0) return
    // No shared writing-mode map; detection is per-section to ensure overrides are caught reliably.

    const viewport = {
        width: Math.round(doc.documentElement?.clientWidth ?? 0),
        height: Math.round(doc.documentElement?.clientHeight ?? 0),
        dpr: Math.round((doc.defaultView?.devicePixelRatio ?? 1) * 1000) / 1000,
        safeTop: Math.round((globalThis.manabiSafeAreaInsets?.top ?? 0) * 1000) / 1000,
        safeBottom: Math.round((globalThis.manabiSafeAreaInsets?.bottom ?? 0) * 1000) / 1000,
        safeLeft: Math.round((globalThis.manabiSafeAreaInsets?.left ?? 0) * 1000) / 1000,
        safeRight: Math.round((globalThis.manabiSafeAreaInsets?.right ?? 0) * 1000) / 1000,
    }
    logEBookBake('bake:start', {
        reason,
        sectionIndex,
        sections: sections.length,
        viewport,
        bookId: bookId ?? null,
        sectionHref: sectionHref ?? null,
    })
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
    const stableDocRect = await waitForStableDocumentSize(doc)
    logEBookBake('bake:doc-stable', {
        reason,
        sectionIndex,
        rect: stableDocRect ? {
            width: Math.round(stableDocRect.width),
            height: Math.round(stableDocRect.height),
        } : null,
    })

    const bakedTags = []
    const bakedEntryMap = new Map()
    const startTs = performance?.now?.() ?? Date.now()
    const addedBodyClass = MANABI_TRACKING_SIZE_BAKING_OPTIMIZED && !body.classList.contains(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS)

    // Reset any previous bake markers so we always measure fresh sizes.
    for (const el of sections) {
        el.removeAttribute(MANABI_TRACKING_SIZE_BAKED_ATTR)
        el.classList.remove(MANABI_TRACKING_SECTION_BAKED_CLASS)
        el.classList.remove(MANABI_TRACKING_SECTION_BAKE_SKIPPED_CLASS)
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
            if (hasWritingModeOverride(el, vertical)) {
                // Skip cached sizes for mixed writing-mode sections to avoid hardcoding.
                continue
            }
            const inlineSize = Number(entry.inlineSize)
            const blockSize = Number(entry.blockSize)
            if (!Number.isFinite(inlineSize) || !Number.isFinite(blockSize)) continue
            logEBookPerf('RECT.cache-apply', {
                id: el.id || null,
                inlineSize,
                blockSize,
            })
            logEBookPageNumLimited('cache:apply', {
                id: el.id || null,
                inlineSize,
                blockSize,
                vertical,
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

            logEBookPageNumLimited('cache:container-apply', {
                inlineSize,
                blockSize,
                vertical,
            })

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
    const hasContainerCache = bakedEntryMap.has('__container__')
    const appliedFromCache = applyCachedEntries(cachedEntries, container)
    logEBookBake('bake:cache', {
        reason,
        sectionIndex,
        applied: appliedFromCache,
        total: sections.length,
        hasContainerCache,
        cacheKey,
    })
    logEBookPerf('tracking-size-cache-apply', {
        key: cacheKey,
        applied: appliedFromCache,
        total: sections.length,
        missing: Math.max(0, sections.length - appliedFromCache),
    })

    let preMeasuredRects = null

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

        const yokoDescendant = el.querySelector?.('.yoko')
        const skipForWritingMode = yokoDescendant ? true : hasWritingModeOverride(el, vertical)
        if (skipForWritingMode) {
            // Leave natural layout untouched; mark as baked for flow accounting but don't freeze sizes or cache.
            const logical = measureElementLogicalSize(el, vertical)
            const inlineSize = Number(logical?.inlineSize) || 0
            const blockSize = Number(logical?.blockSize) || 0
            el.setAttribute(MANABI_TRACKING_SIZE_BAKED_ATTR, 'skip-writing-mode')
            el.classList.remove(MANABI_TRACKING_SECTION_HIDDEN_CLASS)
            el.classList.add(MANABI_TRACKING_SECTION_BAKE_SKIPPED_CLASS)
            bakedEntryMap.set(el.id || '', {
                id: el.id || '',
                inlineSize,
                blockSize,
                skipCache: true,
            })
            bakedCount++
            logEBookPerf('tracking-size-skip-writing-mode', {
                id: el.id || null,
                inlineSize,
                blockSize,
            })
            logEBookPageNumLimited('tracking-size-skip-writing-mode', {
                id: el.id || null,
                inlineSize,
                blockSize,
                vertical,
            })
            return { inlineSize, blockSize, multiColumn: false }
        }

        try {
            await waitForStableSectionSize(el)
            const sizes = measureSectionSizes(el, vertical, preMeasuredRects)
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
            logEBookBake('bake:viewport-ready', {
                reason,
                sectionIndex,
                bakedCount,
                coverageBlock,
                target: initialViewportBlockTarget,
            })
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

    // Pre-collect rects in a single layout pass to avoid repeated reflows per section.
    try {
        // one forced layout upfront
        doc?.body?.getBoundingClientRect?.()
        const map = new Map()
        for (const el of sections) {
            const id = el?.id
            if (!id) continue
            const rects = Array.from(el.getClientRects?.() ?? []).filter(r => r && (r.width || r.height))
            if (rects.length > 0) {
                map.set(id, rects)
            }
        }
        preMeasuredRects = map
        logEBookPerf('RECT.batch-collected', { count: preMeasuredRects.size })
    } catch (error) {
        // fall back silently
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

        try {
            const handler = globalThis.webkit?.messageHandlers?.[MANABI_TRACKING_CACHE_HANDLER]
            const entriesForCache = Array.from(bakedEntryMap.values()).filter(e => !e.skipCache)
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

    const durationMs = (performance?.now?.() ?? Date.now()) - startTs
    const containerEntry = bakedEntryMap.get('__container__') || null
    logEBookBake('bake:done', {
        reason,
        sectionIndex,
        durationMs: Math.round(durationMs),
        bakedCount,
        multiColumnCount,
        coverageBlock,
        target: initialViewportBlockTarget,
        initialViewportReleased,
        appliedFromCache,
        containerSize: containerEntry ? {
            inline: containerEntry.inlineSize,
            block: containerEntry.blockSize,
        } : null,
    })
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

const hasWritingModeOverride = (section, vertical, { maxNodes = Infinity } = {}) => {
    if (!(section instanceof Element)) return false

    let rootMode = 'horizontal-tb'
    try {
        const cs = section.ownerDocument?.defaultView?.getComputedStyle?.(section)
        const mode =
            cs?.writingMode ||
            cs?.webkitWritingMode ||
            cs?.getPropertyValue?.('writing-mode') ||
            cs?.getPropertyValue?.('-webkit-writing-mode') ||
            ''
        if (mode) rootMode = mode
    } catch {}
    const rootVertical = rootMode ? rootMode.startsWith('vertical') : vertical

    const yokoProbe = section.querySelector?.('.yoko')
    if (yokoProbe) {
        let yokoMode = ''
        try {
            const cs = yokoProbe.ownerDocument?.defaultView?.getComputedStyle?.(yokoProbe)
            yokoMode =
                cs?.writingMode ||
                cs?.webkitWritingMode ||
                cs?.getPropertyValue?.('writing-mode') ||
                cs?.getPropertyValue?.('-webkit-writing-mode') ||
                ''
        } catch {}
        const yokoIsVertical = yokoMode ? yokoMode.startsWith('vertical') : false
        const yokoOrientationMismatch = yokoIsVertical !== vertical
        const yokoStringMismatch = rootMode && yokoMode && yokoMode !== rootMode
        if (yokoStringMismatch || yokoOrientationMismatch || yokoIsVertical !== rootVertical) {
            return true
        }
    }

    const nodes = section.querySelectorAll('*')
    let visited = 0
    for (const el of nodes) {
        if (!(el instanceof Element)) continue
        visited++
        if (visited > maxNodes) break
        let mode = ''
        try {
            const cs = el.ownerDocument?.defaultView?.getComputedStyle?.(el)
            mode =
                cs?.writingMode ||
                cs?.webkitWritingMode ||
                cs?.getPropertyValue?.('writing-mode') ||
                cs?.getPropertyValue?.('-webkit-writing-mode') ||
                ''
        } catch {}

        if (el.classList?.contains?.('yoko') && !mode) mode = 'horizontal-tb'
        if (!mode) continue

        const isVertical = mode.startsWith('vertical')
        const orientationMismatch = isVertical !== vertical
        const stringMismatch = rootMode && mode && mode !== rootMode
        if (stringMismatch || orientationMismatch || isVertical !== rootVertical) {
            return true
        }
    }

    return false
}

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
 * Shared foliate direction resolver (mirrored by reader-mode runtime).
 * @returns {Promise<{vertical: boolean, verticalRTL: boolean, rtl: boolean}>}
 */
function resolvePaginatorDirection({
    bodylessStyle,
    bodylessDoc,
    writingDirectionOverride = globalThis.manabiEbookWritingDirection || 'original',
}) {
    const writingMode = bodylessStyle.writingMode;
    const direction = bodylessStyle.direction;
    const rtl =
        bodylessDoc.body.dir === 'rtl' ||
        direction === 'rtl' ||
        bodylessDoc.documentElement.dir === 'rtl';
    if (writingDirectionOverride === 'vertical') {
        return { vertical: true, verticalRTL: true, rtl };
    }
    if (writingDirectionOverride === 'horizontal') {
        return { vertical: false, verticalRTL: false, rtl };
    }
    const vertical = writingMode === 'vertical-rl' || writingMode === 'vertical-lr';
    const verticalRTL = writingMode === 'vertical-rl';
    return { vertical, verticalRTL, rtl };
}
globalThis.manabiResolvePaginatorDirection = resolvePaginatorDirection;

async function getDirection({ bodylessStyle, bodylessDoc }) {
    return resolvePaginatorDirection({ bodylessStyle, bodylessDoc });
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
    #pendingResizeAfterExpand = null
    #expandRetryScheduled = false
    cachedViewSize = null
    getLastBodyRect() {
        // Rounded body rect captured by the resize observer; avoids forcing layout reads elsewhere.
        return this.#lastBodyRect
    }
    #handleResize(newSize) {
        if (!newSize) return
        const inExpand = this.#inExpand || false
        // Keep resize lightweight: invalidate cached sizes and ask container to re-bake when enabled.
        if (this.#isCacheWarmer) return
        this.#lastBodyRect = newSize
        if (inExpand) {
            // Buffer the last resize that arrives while expand is running so we can replay it afterwards.
            this.#pendingResizeAfterExpand = newSize
            logEBookResize('iframe-resize-buffered', {
                newSize,
                inExpand,
                isCacheWarmer: this.#isCacheWarmer,
            })
            console.log('[paginator] handleResize buffered during expand', { newSize, inExpand })
            return
        }
        logEBookResize('iframe-resize-apply', {
            newSize,
            inExpand,
            isCacheWarmer: this.#isCacheWarmer,
        })
        console.log('[paginator] handleResize apply', { newSize, inExpand })
        this.cachedViewSize = null
        if (MANABI_TRACKING_SIZE_BAKE_ENABLED) {
            this.container?.requestTrackingSectionSizeBakeDebounced?.({
                reason: 'iframe-resize',
                rect: newSize,
            })
        } else {
            this.expand().catch(() => {})
        }
    }
    #element = document.createElement('div')
    #iframe = document.createElement('iframe')
    #iframeShownForBake = false
    #contentRange = document.createRange()
    #overlayer
    #vertical = null
    #verticalRTL = null
    #rtl = null
    #directionReadyResolve = null;
    #directionReady = new Promise(r => (this.#directionReadyResolve = r));
    #column = true
    #size
    #lastElementStyleHeight = null
    #elementStyleObserver = null
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
        // Watch for unexpected inline height mutations on the view wrapper, which can cause page spikes.
        this.#lastElementStyleHeight = this.#element.style.height || null
        this.#elementStyleObserver = new MutationObserver(mutations => {
            for (const m of mutations) {
                if (m.attributeName !== 'style') continue
                const current = this.#element.style.height || null
                if (current === this.#lastElementStyleHeight) continue
                const prevNumeric = parseFloat(this.#lastElementStyleHeight ?? 'NaN')
                const currentNumeric = parseFloat(current ?? 'NaN')
                const isSpike = Number.isFinite(currentNumeric) && currentNumeric > 4000
                if (isSpike || current !== this.#lastElementStyleHeight) {
                    logEBookPageNumLimited('element-style-height', {
                        previous: this.#lastElementStyleHeight,
                        next: current,
                        isSpike,
                    })
                }
                this.#lastElementStyleHeight = current
            }
        })
        try {
            this.#elementStyleObserver.observe(this.#element, { attributes: true, attributeFilter: ['style'] })
        } catch (_) {}
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
        if (this.#iframeShownForBake) return
        if (this.#iframe?.style?.display === 'none') {
            this.#iframe.style.display = 'block'
            this.#iframeShownForBake = true
            logEBookPerf('iframe-display-set', { state: 'shown-for-bake', reason })
            logEBookPageNumLimited('bake:iframe-reveal', {
                reason,
                sectionIndex: this.container?.currentIndex ?? null,
            })
            logEBookFlash('iframe-reveal', {
                reason,
                sectionIndex: this.container?.currentIndex ?? null,
            })
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
        this.#iframeShownForBake = false
        // Reset direction flags and promise before loading a new section
        this.#vertical = this.#verticalRTL = this.#rtl = null;
        this.#directionReady = new Promise(r => (this.#directionReadyResolve = r));
        // When size baking is enabled, keep the iframe hidden until we're ready to bake/reveal.
        if (MANABI_TRACKING_SIZE_BAKE_ENABLED) {
            this.#iframe.style.display = 'none'
            logEBookPerf('iframe-display-set', { state: 'hidden-before-src', src })
        } else {
            this.#iframe.style.display = 'block'
        }
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
                    applyVerticalWritingClass(doc, this.#vertical)
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
        // Always allow the first render/expand pass; early suppression was causing under-measured layouts.
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

        applyVerticalWritingClass(this.document, this.#vertical)

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
        const canExpand = !skipExpand
        if (canExpand) {
            await this.expand()
        } else if (!skipExpand) {
            logEBookPerf('EXPAND.expand-skip', {
                source: 'scrolled',
                suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                ready: this.container?.trackingSizeBakeReadyPublic ?? null,
            })
        }
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
        const canExpand = !skipExpand
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
        logEBookPageNumLimited('expand:entry', {
            column: this.#column,
            vertical: this.#vertical,
            size: this.#size,
            cacheWarmer: this.#isCacheWarmer,
            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
            trackingReady: this.container?.trackingSizeBakeReadyPublic ?? null,
            pendingReason: this.container?.pendingTrackingSizeBakeReasonPublic ?? null,
            inExpand: this.#inExpand || false,
        })
        // Reset per-expand retry state; invalid measurements schedule a single retry.
        this.#expandRetryScheduled = false
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
                        const contentRectSide = contentRect?.[side] ?? 0
                        const contentSize = contentStart + contentRectSide
                        const sizeValid = Number.isFinite(this.#size) && this.#size > 0
                        const contentRectValid = Number.isFinite(contentRectSide) && contentRectSide > 0
                        const contentSizeValid = Number.isFinite(contentSize) && contentSize > 0
                        const pageCount = (sizeValid && contentSizeValid)
                            ? Math.ceil(contentSize / this.#size)
                            : null
                        const invalidMeasurement = !sizeValid || !contentRectValid || !contentSizeValid || !pageCount || pageCount <= 0
                        console.log('[paginator] expand measure', {
                            size: this.#size,
                            side,
                            contentRectSide,
                            contentStart,
                            contentSize,
                            pageCount,
                            invalidMeasurement,
                        })
                        if (invalidMeasurement) {
                            logEBookPageNumLimited('expand:invalid-measurement', {
                                mode: 'column',
                                side,
                                size: this.#size,
                                contentRectSide,
                                contentStart,
                                contentSize,
                                pageCount,
                            })
                            logEBookBake('expand:invalid-measurement', {
                                mode: 'column',
                                side,
                                size: this.#size,
                                contentRectSide,
                                contentStart,
                                contentSize,
                                pageCount,
                                column: this.#column,
                                vertical: this.#vertical,
                                readyFlag: this.container?.trackingSizeBakeReadyPublic ?? null,
                                suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                            })
                            // Defer a retry so we don't lock in a bogus 0/1 page count; often fonts/images finish after this.
                            if (!this.#expandRetryScheduled) {
                                this.#expandRetryScheduled = true
                                requestAnimationFrame(() => {
                                    this.#expandRetryScheduled = false
                                    if (!this.#inExpand) this.expand().catch(() => {})
                                })
                            }
                            return
                        }
                        logEBookPerf('EXPAND.metrics', {
                            mode: 'column',
                            side,
                            size: this.#size,
                            contentSize,
                            pageCount,
                            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                            ready: this.container?.trackingSizeBakeReadyPublic ?? null,
                        })
                        logEBookPageNumLimited('expand:metrics', {
                            mode: 'column',
                            side,
                            size: this.#size,
                            contentSize,
                            pageCount,
                            expandedSize: pageCount * this.#size,
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
                        logEBookPageNumLimited('expand:metrics', {
                            mode: 'scrolled',
                            side,
                            size: this.#size,
                            contentSize,
                            pageCount: null,
                            expandedSize,
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
                    logEBookPageNumLimited('expand:set-styles', {
                        column: this.#column,
                        vertical: this.#vertical,
                        side,
                        iframe: this.#iframe?.style?.[side] || null,
                        element: this.#element?.style?.[side] || null,
                        otherSide,
                        iframeOther: this.#iframe?.style?.[otherSide] || null,
                        elementOther: this.#element?.style?.[otherSide] || null,
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
                    logEBookPageNumLimited('expand:complete', {
                        column: this.#column,
                        vertical: this.#vertical,
                        size: this.#size,
                        suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                        trackingReady: this.container?.trackingSizeBakeReadyPublic ?? null,
                        pendingReason: this.container?.pendingTrackingSizeBakeReasonPublic ?? null,
                    })
                    //                console.log("expand... call'd onexpand")
                } finally {
                    const bufferedResize = this.#pendingResizeAfterExpand
                    this.#pendingResizeAfterExpand = null
                    this.#inExpand = false
                    if (bufferedResize) {
                        console.log('[paginator] expand: replay buffered resize after expand', bufferedResize)
                        this.#handleResize(bufferedResize)
                    }
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
    #logChevronDispatch(_event, _payload = {}) {}
    #emitChevronOpacity(detail, source) {
        if (!CHEVRON_VISUALS_ENABLED) return;
        const nextLeft = detail?.leftOpacity ?? null;
        const nextRight = detail?.rightOpacity ?? null;
        if (this.#lastChevronEmit.left === nextLeft && this.#lastChevronEmit.right === nextRight) {
            this.#logChevronDispatch('sideNavChevronOpacity:ignoredDuplicate', {
                source: source ?? null,
                leftOpacity: nextLeft,
                rightOpacity: nextRight,
                bookDir: this.bookDir ?? null,
                rtl: this.#rtl,
            });
            return;
        }
        this.#lastChevronEmit = { left: nextLeft, right: nextRight };
        const payload = { ...detail };
        if (source !== undefined) payload.source = source;
        const shouldLog = (
            payload?.leftOpacity === '' ||
            payload?.rightOpacity === '' ||
            Number(payload?.leftOpacity) >= 1 ||
            Number(payload?.rightOpacity) >= 1 ||
            (typeof source === 'string' && source.includes('reset'))
        );
        if (shouldLog) {
            this.#logChevronDispatch('sideNavChevronOpacity:emit', {
                source: payload?.source ?? null,
                leftOpacity: payload?.leftOpacity ?? null,
                rightOpacity: payload?.rightOpacity ?? null,
                bookDir: this.bookDir ?? null,
                rtl: this.#rtl,
                touchTriggeredNav: this.#touchTriggeredNav,
                touchHasShownChevron: this.#touchHasShownChevron,
                maxLeft: this.#maxChevronLeft,
                maxRight: this.#maxChevronRight,
            });
        }
        this.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
            bubbles: true,
            composed: true,
            detail: payload,
        }));
    }
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

        if (!changed) {
            logEBookResize('container-resize-no-change', {
                newSize,
                old,
            })
            return
        }

        this.#lastResizerRect = newSize
        this.#cachedSizes = null
        this.#cachedStart = null

        logEBookResize('container-resize-change', {
            newSize,
            old,
        })

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
                    stable.height === this.#lastResizerRect?.height

                if (!still) {
                    logEBookResize('container-resize-unstable', {
                        stable,
                        last: this.#lastResizerRect,
                        compareTopLeft: true,
                    })
                    return
                }

                logEBookResize('container-resize-bake', {
                    stable,
                    reason: 'container-resize',
                    note: 'top/left ignored for stability',
                })

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
    #loadingReason = null
    #hasExpandedOnce = false
    #activeBakeCount = 0
    #sizeBakeDebounceTimer = null
    #sizeBakeDebounceArgs = null
    #trackingSizeBakeQueuedRect = null
    get currentIndex() { return this.#index }
    #anchor = 0 // anchor view to a fraction (0-1), Range, or Element
    #justAnchored = false
    #isLoading = false
    #locked = false // while true, prevent any further navigation
    #lockTimestamp = 0
    #styles
    #styleMap = new WeakMap()
    #scrollBounds
    #touchState
    #touchScrolled
    #isCacheWarmer = false
    #prefetchTimer = null
    #prefetchCache = new Map()
    #schedulePrefetchLoad(index) {
        const start = () => this.sections[index].load().catch(() => { });
        const ric = globalThis.requestIdleCallback;
        const promise = typeof ric === 'function'
            ? new Promise(resolve => ric(() => resolve(start()), { timeout: 500 }))
            : new Promise(resolve => setTimeout(() => resolve(start()), 50));
        this.#prefetchCache.set(index, promise);
    }
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
    #skipNextExpandBake = false
    requestTrackingSectionSizeBakeDebounced = (args) => {
        logEBookResize('size-bake-requested', {
            reason: args?.reason ?? 'unspecified',
            rectProvided: !!args?.rect,
        })
        if (this.#sizeBakeDebounceTimer) {
            clearTimeout(this.#sizeBakeDebounceTimer)
        }
        this.#sizeBakeDebounceArgs = args
        this.#sizeBakeDebounceTimer = setTimeout(() => {
            const pending = this.#sizeBakeDebounceArgs
            this.#sizeBakeDebounceTimer = null
            this.#sizeBakeDebounceArgs = null
            logEBookResize('size-bake-debounced-fire', {
                reason: pending?.reason ?? 'unspecified',
                rectProvided: !!pending?.rect,
            })
            this.requestTrackingSectionSizeBake(pending)
        }, 240)
        return true
    }
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
    #hasSentinels = false
    #lastSizesSnapshot = null
    #lastViewSizeSnapshot = null

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

        // Keep chevron emitter state aligned with any external resets
        document.removeEventListener('resetSideNavChevrons', this.#handleChevronResetEvent);
        document.addEventListener('resetSideNavChevrons', this.#handleChevronResetEvent);

        if (!this.#isCacheWarmer) {
            const opts = {
                passive: false
            }
            this.addEventListener('touchstart', this.#onTouchStart.bind(this), opts)
            this.addEventListener('touchmove', this.#onTouchMove.bind(this), opts)
            this.addEventListener('touchend', this.#onTouchEnd.bind(this))
            this.addEventListener('touchcancel', this.#onTouchCancel.bind(this))
            this.addEventListener('load', ({
                detail: {
                    doc
                }
            }) => {
                doc.addEventListener('touchstart', this.#onTouchStart.bind(this), opts)
                doc.addEventListener('touchmove', this.#onTouchMove.bind(this), opts)
                doc.addEventListener('touchend', this.#onTouchEnd.bind(this))
                doc.addEventListener('touchcancel', this.#onTouchCancel.bind(this))
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
        this.#hasExpandedOnce = false
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
    #setLoading(isLoading, reason = 'unspecified') {
        const isExpand = reason === 'expand'
        if (isLoading && isExpand && this.#hasExpandedOnce && !this.#isLoading) {
            this.#loadingReason = reason || this.#loadingReason || 'unspecified'
            logEBookFlash('loading-skip', {
                sectionIndex: this.#index,
                reason: this.#loadingReason,
                hasExpandedOnce: this.#hasExpandedOnce,
                isCacheWarmer: this.#isCacheWarmer,
            })
            return
        }
        if (this.#isLoading === isLoading) return
        this.#isLoading = isLoading;
        this.#loadingReason = reason || this.#loadingReason || 'unspecified'
        if (isLoading) {
            this.#top.classList.add('reader-loading');
            logEBookFlash('loading-start', {
                sectionIndex: this.#index,
                reason: this.#loadingReason,
            })
        } else {
            this.#top.classList.remove('reader-loading');
            logEBookFlash('loading-stop', {
                sectionIndex: this.#index,
                reason: this.#loadingReason,
            })
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
            logEBookResize('size-bake-skip', {
                reason,
                sectionIndex: sectionIndex ?? this.#index,
                status: 'skip-not-ready-styles-applied',
                ready: this.#trackingSizeBakeReady,
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
            this.#setLoading(false, 'size-bake-disabled')
            return false
        }
        if (this.#isCacheWarmer) return false
        if (!this.#view?.document) {
            logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'no-document' })
            logEBookResize('size-bake-skip', { ...ctxBase, status: 'no-document' })
            this.#pendingTrackingSizeBakeReason = reason
            return false
        }
        if (!this.#trackingSizeBakeReady) {
            logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'not-ready' })
            logEBookResize('size-bake-skip', { ...ctxBase, status: 'not-ready' })
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
                logEBookResize('size-bake-skip', { ...ctxBase, status: 'unchanged-rect', rect })
                return false
            }
            this.#trackingSizeLastObservedRect = rect
        } else {
            // Only respond to rects captured elsewhere (e.g., resize observer cache); avoid new layout reads here.
            const cachedBodyRect = this.#view?.getLastBodyRect?.()
            if (!cachedBodyRect) {
                logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'no-cached-rect' })
                logEBookResize('size-bake-skip', { ...ctxBase, status: 'no-cached-rect' })
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
                logEBookResize('size-bake-skip', { ...ctxBase, status: 'unchanged-derived', derived })
                return false
            }
            this.#trackingSizeLastObservedRect = derived
        }

        if (this.#trackingSizeBakeInFlight) {
            const sameQueuedReason = this.#trackingSizeBakeQueuedReason === reason
            const sameQueuedRect = rect && this.#trackingSizeBakeQueuedRect &&
                rect.width === this.#trackingSizeBakeQueuedRect.width &&
                rect.height === this.#trackingSizeBakeQueuedRect.height &&
                rect.top === this.#trackingSizeBakeQueuedRect.top &&
                rect.left === this.#trackingSizeBakeQueuedRect.left

            if (sameQueuedReason && sameQueuedRect) {
                logEBookResize('size-bake-queued-skip-same', { ...ctxBase, rectProvided: !!rect })
                return true
            }

            this.#trackingSizeBakeNeedsRerun = true
            this.#trackingSizeBakeQueuedReason = reason
            this.#trackingSizeBakeQueuedRect = rect || this.#trackingSizeBakeQueuedRect
            logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'queued-rerun' })
            logEBookPageNumLimited('bake:request', { ...ctxBase, status: 'queued-rerun' })
            logEBookResize('size-bake-queued-rerun', { ...ctxBase, rectProvided: !!rect, rect })
            return true
        }

        this.#trackingSizeBakeQueuedReason = null
        this.#trackingSizeBakeNeedsRerun = false
        this.#trackingSizeBakeQueuedRect = null

        logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'start' })
        logEBookPageNumLimited('bake:request', { ...ctxBase, status: 'start', rectProvided: !!rect })
        logEBookResize('size-bake-start', { ...ctxBase, rectProvided: !!rect, rect })
        this.#trackingSizeBakeInFlight = this.#performTrackingSectionSizeBake({
            reason,
            sectionIndex: sectionIndex ?? this.#index,
            skipPostBakeRefresh,
        }).catch(error => {
            // swallow bake errors after reporting if needed
            console.error('tracking size bake error', error)
            logEBookPageNumLimited('bake:error', { ...ctxBase, error: String(error) })
            logEBookResize('size-bake-error', { ...ctxBase, error: String(error) })
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
        this.#skipNextExpandBake = false
        this.#loadingReason = null

        this.#cachedSentinelDoc = null
        this.#cachedSentinelElements = []
        this.#cachedTrackingSections = []

        logEBookPageNumLimited('bake:reset-state', {
            sectionIndex: this.#index ?? null,
        })
    }

    #revealPreBakeContent() {
        if (!this.#view?.document) return
        revealDocumentContentForBake(this.#view.document)
        logEBookPageNumLimited('bake:reveal-prebake-content', {
            sectionIndex: this.#index ?? null,
        })
    }

    // Public helper for View to force an initial size bake before first expand.
    async performInitialBakeFromView(sectionIndex, layout) {
        if (!MANABI_TRACKING_SIZE_BAKE_ENABLED) {
            // When baking is off, we still need a first render+expand so pagination works.
            this.#suppressBakeOnExpand = false
            this.#trackingSizeBakeReady = true
            logEBookPageNumLimited('bake:initial:skipped', {
                sectionIndex,
                suppressBakeOnExpand: this.#suppressBakeOnExpand,
                readyFlag: this.#trackingSizeBakeReady,
            })
            await this.#view?.render(layout, { source: 'initial-bake-disabled' })
            return
        }
        // Lock expands and reset readiness before pre-bake render.
        this.#suppressBakeOnExpand = true
        this.#trackingSizeBakeReady = false
        logEBookBake('initial-bake:start', {
            sectionIndex,
            suppressBakeOnExpand: this.#suppressBakeOnExpand,
        })
        logEBookPageNumLimited('bake:initial:start', {
            sectionIndex,
            suppressBakeOnExpand: this.#suppressBakeOnExpand,
            readyFlag: this.#trackingSizeBakeReady,
        })

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
            logEBookBake('initial-bake:after-perform', {
                sectionIndex,
                ready: this.#trackingSizeBakeReady,
                suppressBakeOnExpand: this.#suppressBakeOnExpand,
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
        this.#skipNextExpandBake = true
        logEBookBake('initial-bake:post-render-begin', {
            sectionIndex,
            ready: this.#trackingSizeBakeReady,
            suppressBakeOnExpand: this.#suppressBakeOnExpand,
        })
        await this.#view?.render(layout, { source: 'initial-bake-post-render' })
        logEBookPerf('EXPAND.callsite', {
            source: 'initial-bake-after-render',
            suppressBakeOnExpand: this.#suppressBakeOnExpand,
            ready: this.#trackingSizeBakeReady,
            bodyHidden: this.view?.document?.body?.classList?.contains?.(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS) ?? null,
        })
        logEBookPageNumLimited('bake:initial:done', {
            sectionIndex,
            ready: this.#trackingSizeBakeReady,
            suppressBakeOnExpand: this.#suppressBakeOnExpand,
        })
        logEBookBake('initial-bake:done', {
            sectionIndex,
            ready: this.#trackingSizeBakeReady,
            suppressBakeOnExpand: this.#suppressBakeOnExpand,
        })
    }

    async #performTrackingSectionSizeBake({
        reason = 'unspecified',
        sectionIndex = null,
        skipPostBakeRefresh = false,
    } = {}) {
        if (!MANABI_TRACKING_SIZE_BAKE_ENABLED) {
            logEBookPageNumLimited('bake:begin', {
                reason,
                sectionIndex,
                status: 'disabled',
            })
            this.#setLoading(false, 'size-bake-disabled')
            return
        }
        const perfStart = performance?.now?.() ?? null
        const doc = this.#view?.document
        if (!doc) {
            logEBookPerf('tracking-size-bake-begin', {
                reason,
                sectionIndex,
                status: 'no-doc',
            })
            logEBookPageNumLimited('bake:begin', {
                reason,
                sectionIndex,
                status: 'no-doc',
            })
            this.#setLoading(false, 'size-bake-no-doc')
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
        logEBookPageNumLimited('bake:begin', {
            reason,
            sectionIndex,
            isCacheWarmer: this.#isCacheWarmer,
            hasDoc: !!doc,
            readyFlag: this.#trackingSizeBakeReady,
            pendingReason: this.#pendingTrackingSizeBakeReason ?? null,
        })
        logEBookBake('bake:begin', {
            reason,
            sectionIndex,
            isCacheWarmer: this.#isCacheWarmer,
            readyFlag: this.#trackingSizeBakeReady,
            pendingReason: this.#pendingTrackingSizeBakeReason ?? null,
        })
        logEBookFlash('size-bake-begin', {
            sectionIndex: sectionIndex ?? this.#index,
            reason,
            activeBakeCount: this.#activeBakeCount,
            hasExpandedOnce: this.#hasExpandedOnce,
            loadingReason: this.#loadingReason,
            isLoading: this.#isLoading,
        })

        const activeView = this.#view

        this.#activeBakeCount += 1
        if (this.#activeBakeCount === 1) {
            const shouldShowLoading = !(this.#hasExpandedOnce && reason !== 'initial-load')
            if (shouldShowLoading) {
                this.#setLoading(true, 'size-bake')
            } else {
                // Avoid reapplying the loading opacity mask on post-expand resize bakes; it causes a visible flash.
                logEBookFlash('loading-skip', {
                    sectionIndex: sectionIndex ?? this.#index,
                    reason: 'size-bake',
                    bakeReason: reason,
                    hasExpandedOnce: this.#hasExpandedOnce,
                    isCacheWarmer: this.#isCacheWarmer,
                })
            }
        }
        hideDocumentContentForPreBake(doc)
        this.#trackingSizeBakeReady = false
        logEBookPageNumLimited('bake:flag-reset-false', {
            reason,
            sectionIndex,
        })
        logEBookBake('bake:flag-reset', {
            reason,
            sectionIndex,
        })
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
            logEBookPageNumLimited('bake:last-baked-rect', {
                sectionIndex,
                rect: this.#lastTrackingSizeBakedRect,
            })
        }

        // Clear any queued rect once a bake starts; new requests will set it again if needed.
        this.#trackingSizeBakeQueuedRect = null

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
                this.#activeBakeCount = Math.max(0, this.#activeBakeCount - 1)
                const keepLoading =
                    this.#activeBakeCount > 0 ||
                    !!this.#sizeBakeDebounceTimer ||
                    !!this.#trackingSizeBakeNeedsRerun

                if (keepLoading) {
                    logEBookFlash('loading-keep', {
                        sectionIndex: this.#index,
                        reason: 'size-bake-pending',
                        activeBakeCount: this.#activeBakeCount,
                        debouncePending: !!this.#sizeBakeDebounceTimer,
                        rerunQueued: !!this.#trackingSizeBakeNeedsRerun,
                    })
                } else {
                    this.#setLoading(false, 'size-bake-complete')
                }
                logEBookFlash('size-bake-finish', {
                    sectionIndex: this.#index,
                    reason,
                    keepLoading,
                    activeBakeCount: this.#activeBakeCount,
                    debouncePending: !!this.#sizeBakeDebounceTimer,
                    rerunQueued: !!this.#trackingSizeBakeNeedsRerun,
                })
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
                logEBookBake('bake:ready-set', {
                    reason,
                    sectionIndex,
                    durationMs,
                    stillActiveView: this.#view === activeView,
                    lastBakedRect: this.#lastTrackingSizeBakedRect ?? null,
                    lastObservedRect: this.#trackingSizeLastObservedRect ?? null,
                })
                logEBookPageNumLimited('bake:ready-set', {
                    reason,
                    sectionIndex,
                    durationMs,
                    stillActiveView: this.#view === activeView,
                    lastBakedRect: this.#lastTrackingSizeBakedRect ?? null,
                    lastObservedRect: this.#trackingSizeLastObservedRect ?? null,
                    readyFlag: this.#trackingSizeBakeReady,
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
        this.#hasSentinels = total > 0
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
        this.#setLoading(true, 'expand')
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

        this.#hasExpandedOnce = true

        // Avoid clearing loading if a size-bake is currently driving the spinner; let bake completion stop it.
        if (!(this.#isLoading && this.#loadingReason === 'size-bake')) {
            this.#setLoading(false, 'expand')
        }
        const skipNextExpandBake = this.#skipNextExpandBake
        const shouldBake = !this.#suppressBakeOnExpand && !skipNextExpandBake
        this.#skipNextExpandBake = false
        logEBookPerf('on-expand', {
            pendingReason: pendingReason || null,
            suppressBake: this.#suppressBakeOnExpand,
            skipNext: skipNextExpandBake,
            hasDoc: !!this.#view?.document,
            vertical: this.#vertical,
            column: this.#column,
        })
        logEBookPageNumLimited('bake:on-expand', {
            sectionIndex: this.#index ?? null,
            pendingReason: pendingReason || null,
            suppressBake: this.#suppressBakeOnExpand,
            readyFlag: this.#trackingSizeBakeReady,
            skipNext: skipNextExpandBake,
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
        logEBookPageNumLimited('bake:sentinels:init', {
            sectionIndex: this.#index ?? null,
            sentinelCount: sentinelElements.length,
            trackingSections: this.#cachedTrackingSections?.length ?? null,
            allowRetry,
            containerClientWidth: this.#container?.clientWidth ?? null,
            containerClientHeight: this.#container?.clientHeight ?? null,
            containerScrollWidth: this.#container?.scrollWidth ?? null,
            containerScrollHeight: this.#container?.scrollHeight ?? null,
        })

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

        logEBookPageNumLimited('bake:sentinels:snapshot', {
            sectionIndex: this.#index ?? null,
            visibleCount: visibleIds.length,
            minIndex,
            maxIndex,
            observedThisCall,
            totalGroups: this.#sentinelGroups?.length ?? null,
        })
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
        this.#rtl = typeof rtl === 'boolean' ? rtl : (this.bookDir === 'rtl')
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
        // Avoid cached measurements; the iframe can be hidden during load which would
        // record zeros and break pagination. Always read current client sizes.
        const sizes = {
            width: this.#container.clientWidth,
            height: this.#container.clientHeight,
        }
        this.#logSizesOnce({
            event: 'sizes',
            sectionIndex: this.#index ?? null,
            width: sizes.width,
            height: sizes.height,
            scrollWidth: this.#container.scrollWidth,
            scrollHeight: this.#container.scrollHeight,
            scrolled: this.scrolled,
            vertical: this.#vertical,
            rtl: this.#rtl,
            rect: this.#container.getBoundingClientRect ? {
                width: Math.round(this.#container.getBoundingClientRect().width),
                height: Math.round(this.#container.getBoundingClientRect().height),
                top: Math.round(this.#container.getBoundingClientRect().top),
                left: Math.round(this.#container.getBoundingClientRect().left),
            } : null,
            styleHeight: this.#container?.style?.height ?? null,
            overflow: typeof getComputedStyle === 'function'
                ? getComputedStyle(this.#container).overflow
                : null,
            bakeReady: this.#trackingSizeBakeReady,
            pendingBakeReason: this.#pendingTrackingSizeBakeReason ?? null,
            bakeInFlight: !!this.#trackingSizeBakeInFlight,
            usingCache: false,
        })
        return sizes
    }
    async size() {
        const s = (await this.sizes())[await this.sideProp()]
        logEBookPageNumLimited('size', {
            sectionIndex: this.#index ?? null,
            size: s,
            scrolled: this.scrolled,
            vertical: this.#vertical,
            rtl: this.#rtl,
        })
        // Detect collapses or missing layout that can cascade into bogus page counts.
        const container = this.#container
        const containerClientW = container?.clientWidth ?? null
        const containerClientH = container?.clientHeight ?? null
        if (!Number.isFinite(s) || s === 0 || containerClientW === 0 || containerClientH === 0) {
            const rect = container?.getBoundingClientRect?.()
            logEBookPageNumLimited('size:anomaly', {
                sectionIndex: this.#index ?? null,
                size: s,
                clientWidth: containerClientW,
                clientHeight: containerClientH,
                scrollWidth: container?.scrollWidth ?? null,
                scrollHeight: container?.scrollHeight ?? null,
                scrolled: this.scrolled,
                vertical: this.#vertical,
                rtl: this.#rtl,
                rect: rect ? {
                    width: Math.round(rect.width),
                    height: Math.round(rect.height),
                    top: Math.round(rect.top),
                    left: Math.round(rect.left),
                } : null,
            })
        }
        return s
    }
    async viewSize() {
        if (this.#isCacheWarmer) return 0
        const view = this.#view
        if (!view || !view.element) return 0
        const element = view.element
        const side = await this.sideProp()
        const scrollWidth = element.scrollWidth
        const scrollHeight = element.scrollHeight
        const val = (!this.scrolled)
            ? (side === 'width' ? scrollWidth : scrollHeight)
            : (side === 'width' ? element.clientWidth : element.clientHeight)

        this.#logViewSizeOnce({
            event: 'viewSize',
            sectionIndex: this.#index ?? null,
            side,
            clientWidth: element.clientWidth,
            clientHeight: element.clientHeight,
            scrollWidth,
            scrollHeight,
            returned: val,
            scrolled: this.scrolled,
            vertical: this.#vertical,
            rtl: this.#rtl,
            elemRect: element.getBoundingClientRect ? {
                width: Math.round(element.getBoundingClientRect().width),
                height: Math.round(element.getBoundingClientRect().height),
                top: Math.round(element.getBoundingClientRect().top),
                left: Math.round(element.getBoundingClientRect().left),
            } : null,
            parentRect: this.#container?.getBoundingClientRect ? {
                width: Math.round(this.#container.getBoundingClientRect().width),
                height: Math.round(this.#container.getBoundingClientRect().height),
                top: Math.round(this.#container.getBoundingClientRect().top),
                left: Math.round(this.#container.getBoundingClientRect().left),
            } : null,
            elemStyleHeight: element?.style?.height ?? null,
            elemStyleDisplay: element?.style?.display ?? null,
            parentStyleHeight: this.#container?.style?.height ?? null,
            parentOverflow: typeof getComputedStyle === 'function'
                ? getComputedStyle(this.#container).overflow
                : null,
            bakeReady: this.#trackingSizeBakeReady,
            pendingBakeReason: this.#pendingTrackingSizeBakeReason ?? null,
            bakeInFlight: !!this.#trackingSizeBakeInFlight,
            usingCache: false,
        })

        return val
    }
    #logSizesOnce(payload) {
        const key = JSON.stringify({
            width: payload.width,
            height: payload.height,
            scrolled: payload.scrolled,
            vertical: payload.vertical,
            rtl: payload.rtl,
            bakeReady: payload.bakeReady,
            usingCache: payload.usingCache,
            pending: payload.pendingBakeReason ?? null,
        })
        if (this.#lastSizesSnapshot === key) return
        this.#lastSizesSnapshot = key
        logEBookPageNumLimited(payload.event, payload)
    }

    #logViewSizeOnce(payload) {
        const key = JSON.stringify({
            side: payload.side,
            width: payload.cachedWidth ?? payload.clientWidth,
            height: payload.cachedHeight ?? payload.clientHeight,
            scrolled: payload.scrolled,
            vertical: payload.vertical,
            rtl: payload.rtl,
            bakeReady: payload.bakeReady,
            usingCache: payload.usingCache,
            pending: payload.pendingBakeReason ?? null,
        })
        if (this.#lastViewSizeSnapshot === key) return
        this.#lastViewSizeSnapshot = key
        logEBookPageNumLimited(payload.event, payload)
    }
    async start() {
        const scrollProp = await this.scrollProp()
        const raw = this.#container[scrollProp]
        const start = Math.abs(raw)
        logEBookPageNumLimited('start', {
            sectionIndex: this.#index ?? null,
            scrollProp,
            rawScrollValue: raw,
            start,
            scrolled: this.scrolled,
            vertical: this.#vertical,
            rtl: this.#rtl,
        })
        return start
    }
    async end() {
        //        await this.#awaitDirection();
        return (await this.start()) + (await this.size())
    }
    async page() {
        const start = await this.start()
        const end = await this.end()
        const size = await this.size()
        const raw = (start + end) / 2
        const page = Math.floor(raw / size)
        logEBookPageNumLimited('page', {
            sectionIndex: this.#index ?? null,
            start,
            end,
            rawMidpoint: raw,
            size,
            page,
            scrolled: this.scrolled,
            vertical: this.#vertical,
            rtl: this.#rtl,
        })
        return page
    }
    async pages() {
        const viewSize = await this.viewSize()
        const size = await this.size()
        const pages = Math.round(viewSize / size)
        const sentinelAdjusted = MANABI_RENDERER_SENTINEL_ADJUST_ENABLED
            && this.#hasSentinels
            && !this.scrolled
            && !this.#vertical
            && pages > 2;
        const textPages = sentinelAdjusted ? Math.max(1, pages - 2) : pages
        logEBookPageNumLimited('pages', {
            sectionIndex: this.#index ?? null,
            viewSize,
            size,
            pages,
            textPages,
            sentinelAdjusted,
            scrolled: this.scrolled,
            vertical: this.#vertical,
            rtl: this.#rtl,
        })
        // If we ever report a single page while text pages likely exceed 1, log extra context.
        if (pages === 1 && this.#index !== null) {
            logEBookPageNumLimited('pages:single-page', {
                sectionIndex: this.#index,
                viewSize,
                size,
                scrolled: this.scrolled,
                vertical: this.#vertical,
                rtl: this.#rtl,
                containerClientWidth: this.#container?.clientWidth ?? null,
                containerClientHeight: this.#container?.clientHeight ?? null,
                containerScrollHeight: this.#container?.scrollHeight ?? null,
                containerScrollWidth: this.#container?.scrollWidth ?? null,
                viewCachedWidth: this.#view?.cachedViewSize?.width ?? null,
                viewCachedHeight: this.#view?.cachedViewSize?.height ?? null,
                cachedSizes: this.#cachedSizes ? { ...this.#cachedSizes } : null,
                viewClientHeight: this.#view?.element?.clientHeight ?? null,
                viewScrollHeight: this.#view?.element?.scrollHeight ?? null,
                scrollHeightEqualsClientHeight: this.#view?.element ? this.#view.element.scrollHeight === this.#view.element.clientHeight : null,
            })
        }
        return pages
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
        this.#clearPendingChevronReset();
        this.#touchHasShownChevron = false;
        this.#touchTriggeredNav = false;
        this.#maxChevronLeft = 0;
        this.#maxChevronRight = 0;
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

        if (!state.triggered && Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > minSwipe) {
            state.triggered = true;
            const navDetail = dx < 0 ? {
                direction: this.bookDir === 'rtl' ? 'backward' : 'forward',
                leftOpacity: this.bookDir === 'rtl' ? 0 : 1,
                rightOpacity: this.bookDir === 'rtl' ? 1 : 0,
                navigate: this.bookDir === 'rtl' ? () => this.prev() : () => this.next(),
            } : {
                direction: this.bookDir === 'rtl' ? 'forward' : 'backward',
                leftOpacity: this.bookDir === 'rtl' ? 1 : 0,
                rightOpacity: this.bookDir === 'rtl' ? 0 : 1,
                navigate: this.bookDir === 'rtl' ? () => this.next() : () => this.prev(),
            };

            this.#lastSwipeNavAt = Date.now();
            this.#lastSwipeNavDirection = navDetail.direction;
            this.#touchTriggeredNav = true;
            this.#emitChevronOpacity({
                leftOpacity: navDetail.leftOpacity,
                rightOpacity: navDetail.rightOpacity,
                holdMs: this.#chevronTriggerHoldMs,
                fadeMs: this.#chevronFadeMs,
            }, 'swipe:navImmediate');
            this.#logChevronDispatch('swipeNav:trigger', {
                dx,
                dy,
                direction: navDetail.direction,
                bookDir: this.bookDir ?? null,
                rtl: this.#rtl,
            });
            await navDetail.navigate();
            this.#scheduleChevronHide(this.#chevronTriggerHoldMs + 80);
            // After navigation triggered via swipe, proactively reset any stale chevron state.
            this.#logResetNeed('postSwipeNav');
            this.#emitChevronReset('reset:postSwipeNav');
        } else {
            if (CHEVRON_SWIPE_PREVIEW_ENABLED) {
                this.#updateSwipeChevron(dx, minSwipe, 'swipe');
            }
        }
    }
    #onTouchEnd(e) {
        const hadNav = this.#touchTriggeredNav;
        const hadChevron = this.#touchHasShownChevron;

        this.#touchState = null;

        // If we just loaded a new section, skip the opacity reset for non-nav touches
        if (this.#skipTouchEndOpacity && !hadNav) {
            this.#logChevronDispatch('sideNavChevronOpacity:touchEnd:skipReset', { reason: 'skipTouchEndOpacity' });
            this.#skipTouchEndOpacity = false
            this.#touchHasShownChevron = false;
            this.#touchTriggeredNav = false;
            this.#maxChevronLeft = 0;
            this.#maxChevronRight = 0;
            return
        }

        // Always clear any outstanding reset timers once the finger lifts
        this.#clearPendingChevronReset();

        if (hadNav) {
            // Navigation already occurred; force a full chevron reset so UI controls re-enable
            this.#logResetNeed('touchEnd:nav');
            this.#emitChevronReset('reset:touchEndNav');
        } else if (hadChevron) {
            // If swipe never triggered navigation but showed the chevron, fade it out now.
            this.#logResetNeed('touchEnd:noNav');
            this.#scheduleChevronHide(0);
        }

        this.#touchHasShownChevron = false;
        this.#touchTriggeredNav = false;
        this.#maxChevronLeft = 0;
        this.#maxChevronRight = 0;
        this.#skipTouchEndOpacity = false;
    }

    #forceEndTouchGesture(source = 'unknown') {
        // Safety net: clear lingering swipe state after navigation/display completes.
        this.#logResetNeed('forceEndTouchGesture', { source });
        this.#clearPendingChevronReset();
        this.#touchState = null;
        this.#touchHasShownChevron = false;
        this.#touchTriggeredNav = false;
        this.#maxChevronLeft = 0;
        this.#maxChevronRight = 0;
        this.#skipTouchEndOpacity = false;
        this.#emitChevronReset('reset:forceEndTouchGesture');
    }

    #onTouchCancel(e) {
        // Treat cancellation as an end-of-gesture and force-reset chevrons/state.
        const hadGesture = this.#touchHasShownChevron || this.#touchTriggeredNav;
        this.#touchState = null;
        this.#clearPendingChevronReset();
        if (hadGesture) {
            this.#logResetNeed('touchCancel');
            this.#emitChevronReset('reset:touchCancel');
        }
        this.#touchHasShownChevron = false;
        this.#touchTriggeredNav = false;
        this.#maxChevronLeft = 0;
        this.#maxChevronRight = 0;
        this.#skipTouchEndOpacity = false;
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
    #lastSwipeNavAt = null;
    #lastSwipeNavDirection = null; // 'forward' | 'backward'
    #touchHasShownChevron = false;
    #touchTriggeredNav = false;
    #maxChevronLeft = 0;
    #maxChevronRight = 0;
    #lastChevronEmit = { left: null, right: null };
    #chevronTriggerHoldMs = 420;
    #chevronFadeMs = 180;
    #pendingChevronResetTimer = null;
    #resetLoopGuard = false;
    #logResetNeed(reason, extra = {}) {
        try {
            const line = `# EBOOK CHEVRESET NEED ${JSON.stringify({ reason, ...extra })}`;
            window.webkit?.messageHandlers?.print?.postMessage?.(line);
            console.log(line);
        } catch (_err) {}
    }
    #handleChevronResetEvent = () => {
        if (this.#resetLoopGuard) return;
        this.#logResetNeed('external-resetSideNavChevrons');
        this.#emitChevronReset('reset:event');
    };
    #emitChevronReset(source = 'reset:auto') {
        // Stop any in-flight auto-hide timers before fanning out a reset.
        this.#clearPendingChevronReset();
        try {
            const line = `# EBOOK CHEVRESET ${JSON.stringify({ source })}`;
            window.webkit?.messageHandlers?.print?.postMessage?.(line);
            console.log(line);
        } catch (_err) {}
        this.#lastChevronEmit = { left: null, right: null };
        this.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
            bubbles: true,
            composed: true,
            detail: {
                leftOpacity: '',
                rightOpacity: '',
                source,
            },
        }));
        // Fan out to outer shell while preventing self-reentry
        this.#resetLoopGuard = true;
        try {
            document.dispatchEvent(new CustomEvent('resetSideNavChevrons', { detail: { source } }));
        } finally {
            setTimeout(() => { this.#resetLoopGuard = false; }, 0);
        }
    }
    #clearPendingChevronReset() {
        if (!this.#pendingChevronResetTimer) return;
        clearTimeout(this.#pendingChevronResetTimer);
        this.#pendingChevronResetTimer = null;
    }
    #scheduleChevronHide(delayMs = this.#chevronTriggerHoldMs) {
        this.#clearPendingChevronReset();
        this.#logResetNeed('scheduleHide', { delayMs });
        this.#pendingChevronResetTimer = setTimeout(() => {
            this.#pendingChevronResetTimer = null;
            this.#emitChevronOpacity({
                leftOpacity: '',
                rightOpacity: '',
                fadeMs: this.#chevronFadeMs,
            }, 'chevron:autoHide');
            this.#emitChevronReset('reset:autoHide');
        }, delayMs);
    }
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
            this.#emitChevronOpacity({
                leftOpacity: '',
                rightOpacity: ''
            }, 'wheel:momentumFalling');
            this.#lastWheelDeltaX = e.deltaX;
            return;
        }

        if (this.#wheelArmed) {
            if (Math.abs(e.deltaX) > REVEAL_CHEVRON_THRESHOLD) {
                this.#updateSwipeChevron(-e.deltaX, TRIGGER_THRESHOLD, 'wheel:reveal');
            } else {
                this.#updateSwipeChevron(0, TRIGGER_THRESHOLD, 'wheel:resetReveal');
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
            this.#updateSwipeChevron(-e.deltaX, TRIGGER_THRESHOLD, 'wheel:triggered')
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
        logEBookPageNumLimited('scrollToPage', {
            targetPage: page,
            reason,
            smooth: !!smooth,
            sectionIndex: this.#index ?? null,
            size,
            offset,
            rtl: this.#rtl,
            vertical: this.#vertical,
        })
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
        logEBookPageNumLimited('scrollToAnchor:start', {
            reason,
            sectionIndex: this.#index ?? null,
            anchorType: anchor?.nodeType ?? (typeof anchor),
            containerHeight: this.#container?.clientHeight ?? null,
            containerWidth: this.#container?.clientWidth ?? null,
        })
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
            const viewSize = await this.viewSize()
            await this.#scrollTo(anchor * (await this.viewSize()), reason)
            return
        }
        const { pages } = this
        if (!pages) return
        const textPages = await this.pages() - 2
        const newPage = Math.round(anchor * (textPages - 1))
        logEBookPageNumLimited('scrollToAnchor:fraction', {
            reason,
            sectionIndex: this.#index ?? null,
            anchorFraction: anchor,
            textPages,
            targetPage: newPage + 1,
            viewSize: await this.viewSize(),
        })
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
            index,
            sectionIndex: index,
        }

        let pageNumberForDetail = null
        let pageCountForDetail = null
        if (this.scrolled) {
            const [startOffset, totalScrollSize, pageSize] = await Promise.all([
                this.start(),
                this.viewSize(),
                this.size(),
            ])
            pageCountForDetail = (Number.isFinite(totalScrollSize) && Number.isFinite(pageSize) && pageSize > 0)
                ? Math.max(1, Math.round(totalScrollSize / pageSize))
                : null
            detail.fraction = totalScrollSize ? startOffset / totalScrollSize : null
            if (pageCountForDetail != null) {
                const frac = detail.fraction ?? 0
                pageNumberForDetail = Math.max(1, Math.min(pageCountForDetail, Math.floor(frac * pageCountForDetail) + 1))
            }
        } else if ((await this.pages()) > 0) {
            const computePaginatedDetail = async () => {
                const [page, pages, pageSize, startOffset] = await Promise.all([
                    this.page(),
                    this.pages(),
                    this.size(),
                    this.start(),
                ])
            const adjustForSentinels = MANABI_RENDERER_SENTINEL_ADJUST_ENABLED
                && this.#hasSentinels
                && !this.scrolled
                && !this.#vertical
                && pages > 2
                const textPages = adjustForSentinels ? Math.max(1, pages - 2) : pages
                const normalizedOffset = adjustForSentinels
                    ? Math.max(0, startOffset - pageSize) // drop lead sentinel
                    : startOffset
                const textPageNumber = textPages > 0
                    ? Math.min(textPages, Math.floor(normalizedOffset / pageSize) + 1)
                    : 1
                const fractionUsed = textPages > 0
                    ? normalizedOffset / (pageSize * textPages)
                    : null

                return {
                    rawPage: page,
                    rawPages: pages,
                    pageSize,
                    startOffset,
                    normalizedOffset,
                    textPages,
                    textPageNumber: adjustForSentinels ? textPageNumber : Math.max(1, page + 1),
                    fractionUsed,
                    sizeFraction: textPages > 0 ? 1 / textPages : null,
                    adjustForSentinels,
                }
            }

            let pagedDetail = await computePaginatedDetail()
            this.#header.style.visibility = pagedDetail.rawPage > 1 ? 'visible' : 'hidden'

            // If layout wasn’t settled yet (common when iframe was hidden pre‑bake),
            // force one re-measure to pick up the real page count.
            if (!this.scrolled && pagedDetail.textPages <= 1) {
                if (this.#view) {
                    this.#view.cachedViewSize = null
                }
                await new Promise(resolve => requestAnimationFrame(resolve))
                const retryDetail = await computePaginatedDetail()
                if (retryDetail.textPages > pagedDetail.textPages) {
                    pagedDetail = retryDetail
                    logEBookPageNumLimited('relocate:detail:retry', {
                        reason,
                        sectionIndex: index,
                        rawPage: pagedDetail.rawPage,
                        rawPages: pagedDetail.rawPages,
                        pageSize: pagedDetail.pageSize,
                        startOffset: pagedDetail.startOffset,
                        pageCountForDetail: pagedDetail.textPages,
                        pageNumberForDetail: pagedDetail.textPageNumber,
                        fractionUsed: pagedDetail.fractionUsed,
                        sentinelAdjusted: pagedDetail.adjustForSentinels,
                    })
                }
            }

            pageCountForDetail = pagedDetail.textPages
            pageNumberForDetail = pagedDetail.textPageNumber
            detail.fraction = pagedDetail.fractionUsed
            detail.size = pagedDetail.sizeFraction

            logEBookPageNumLimited('relocate:detail:calc', {
                reason,
                sectionIndex: index,
                rawPage: pagedDetail.rawPage,
                rawPages: pagedDetail.rawPages,
                pageSize: pagedDetail.pageSize,
                startOffset: pagedDetail.startOffset,
                normalizedOffset: pagedDetail.normalizedOffset,
                pageCountForDetail,
                pageNumberForDetail,
                fractionUsed: detail.fraction,
                sentinelAdjusted: pagedDetail.adjustForSentinels,
            })
        }
        if (pageNumberForDetail != null) detail.pageNumber = pageNumberForDetail
        if (pageCountForDetail != null) detail.pageCount = pageCountForDetail

        const detailForLog = {
            reason,
            sectionIndex: index,
            scrolled: this.scrolled,
            fraction: detail.fraction ?? null,
            sizeFraction: detail.size ?? null,
            pageNumber: pageNumberForDetail,
            pageCount: pageCountForDetail,
        }
        logEBookPageNumLimited('relocate:detail', detailForLog)

        this.dispatchEvent(new CustomEvent('relocate', {
            detail
        }))

        try {
            const [pageNumberRaw, pageCountRaw, startOffset, pageSize, viewSize] = await Promise.all([
                this.page(),
                this.pages(),
                this.start(),
                this.size(),
                this.viewSize(),
            ])
            const sentinelAdjusted = MANABI_RENDERER_SENTINEL_ADJUST_ENABLED
                && !this.scrolled
                && !this.#vertical
                && pageCountRaw > 2;
            const pageCountText = sentinelAdjusted ? Math.max(1, pageCountRaw - 2) : pageCountRaw;
            const pageNumberText = sentinelAdjusted
                ? Math.max(1, Math.min(pageCountText, pageNumberRaw)) // raw is 0-based; text pages shift by one lead sentinel
                : Math.max(1, pageNumberRaw);
            logEBookPageNumLimited('afterScroll:metrics', {
                ...detailForLog,
                pageNumber: pageNumberText,
                pageCount: pageCountText,
                pageNumberRaw,
                pageCountRaw,
                sentinelAdjusted,
                startOffset,
                pageSize,
                viewSize,
            })
        } catch (_error) {
            logEBookPageNumLimited('afterScroll:metrics-error', {
                ...detailForLog,
                error: String(_error),
            })
            // diagnostics best-effort
        }

        // Force chevron visible at start of sections (now handled here, not in ebook-viewer.js)
        if (await this.isAtSectionStart()) {
            if (this.#touchTriggeredNav) {
                this.#logChevronDispatch('sideNavChevronOpacity:startOfSection:skip', {
                    reason: 'navTriggered',
                    bookDir: this.bookDir ?? null,
                    rtl: this.#rtl,
                });
            } else {
                this.#skipTouchEndOpacity = true
                this.#emitChevronOpacity({
                    leftOpacity: this.bookDir === 'rtl' ? 0.999 : 0,
                    rightOpacity: this.bookDir === 'rtl' ? 0 : 0.999,
                }, 'afterScroll:startOfSection');
            }
        }
    }

    #updateSwipeChevron(dx, minSwipe, source = 'swipe') {
        let leftOpacity = 0,
            rightOpacity = 0;
        if (dx > 0) leftOpacity = Math.min(1, dx / minSwipe);
        else if (dx < 0) rightOpacity = Math.min(1, -dx / minSwipe);
        if (leftOpacity > 0 || rightOpacity > 0) {
            this.#touchHasShownChevron = true;
        }
        this.#maxChevronLeft = Math.max(this.#maxChevronLeft, Number(leftOpacity) || 0);
        this.#maxChevronRight = Math.max(this.#maxChevronRight, Number(rightOpacity) || 0);
        this.#emitChevronOpacity({
            leftOpacity,
            rightOpacity,
            fadeMs: this.#chevronFadeMs,
        }, source);
    }
    async #display(promise) {
        //            console.log("#display...")
        this.#setLoading(true, 'display')
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
                        if (MANABI_TRACKING_SIZE_BAKE_ENABLED) ensureTrackingSizeBakeStyles(doc)
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
            logEBookPageNumLimited('display:initial', {
                index,
                reason,
                pageNumber,
                pageCount,
            })
        } catch (_error) {
            logEBookPageNumLimited('display:initial-error', {
                index,
                reason,
                error: String(_error),
            })
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
        this.#setLoading(false, 'display-complete')
        this.#forceEndTouchGesture('didDisplay')
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
                        this.#schedulePrefetchLoad(i)
                    }
                });
            }, 500);
        }
    }
    async goTo(target) {
        if (this.#locked) {
            const now = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
            const elapsed = now - this.#lockTimestamp;
            if (elapsed > 400) {
                this.#locked = false;
                logBug?.('paginator:watchdog-unlock-goTo', { elapsedMs: elapsed });
            } else {
                logBug?.('paginator:locked-goTo', { elapsedMs: elapsed });
                return;
            }
        }
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
        if (this.#locked) {
            const now = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
            const elapsed = now - this.#lockTimestamp;
            if (elapsed > 400) {
                this.#locked = false;
                logBug?.('paginator:watchdog-unlock-turnPage', { dir, elapsedMs: elapsed });
            } else {
                logBug?.('paginator:locked-turnPage', { dir, elapsedMs: elapsed });
                return;
            }
        }

        this.#locked = true
        this.#lockTimestamp = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
        logBug?.('paginator:turnPage:start', { dir, distance });
        try {
            const prev = dir === -1
            const shouldGo = await (prev ? await this.#scrollPrev(distance) : await this.#scrollNext(distance))
            logBug?.('paginator:turnPage:shouldGo', { dir, shouldGo });
            if (shouldGo) {
                await this.#goTo({
                    index: this.#adjacentIndex(dir),
                    anchor: prev ? () => 1 : () => 0,
                    reason: 'page',
                })
            }
            if (shouldGo || !this.hasAttribute('animated')) {
                await wait(100)
            }
        } finally {
            // Never leave the paginator locked if navigation threw/cancelled.
            this.#locked = false
            logBug?.('paginator:turnPage:end', { dir });
        }
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
