import { EbookSectionLayout } from './ebook-section-layout.js'

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

const COLUMNIZATION_CHARACTER_THRESHOLDS = {
    verticalFullWidthCharacters: 40,
    horizontalFullWidthCharacters: 30,
    sampleCount: 20,
}

const parsePixelValue = value => {
    if (value == null) return null
    const parsed = Number.parseFloat(String(value).trim())
    return Number.isFinite(parsed) ? parsed : null
}

const fallbackFullWidthCharacterAdvancePx = doc => {
    const style = doc?.defaultView?.getComputedStyle?.(doc?.body || doc?.documentElement)
    const fontSize = parsePixelValue(style?.fontSize || style?.getPropertyValue?.('font-size'))
    return Math.max(1, fontSize || 16)
}

const measureFullWidthCharacterAdvancePx = ({ doc, vertical }) => {
    const container = doc?.body || doc?.documentElement
    if (!(container instanceof HTMLElement)) {
        return fallbackFullWidthCharacterAdvancePx(doc)
    }

    const probe = doc.createElement('span')
    probe.textContent = '漢'.repeat(COLUMNIZATION_CHARACTER_THRESHOLDS.sampleCount)
    probe.setAttribute('aria-hidden', 'true')
    Object.assign(probe.style, {
        position: 'absolute',
        visibility: 'hidden',
        pointerEvents: 'none',
        whiteSpace: 'nowrap',
        inset: '0',
        font: 'inherit',
        lineHeight: 'inherit',
        letterSpacing: 'normal',
        writingMode: vertical ? 'vertical-rl' : 'horizontal-tb',
        textOrientation: vertical ? 'upright' : 'mixed',
    })

    container.appendChild(probe)
    const rect = probe.getBoundingClientRect()
    probe.remove()

    const measuredSpan = vertical ? rect.height : rect.width
    if (measuredSpan > 0) return measuredSpan / COLUMNIZATION_CHARACTER_THRESHOLDS.sampleCount
    return fallbackFullWidthCharacterAdvancePx(doc)
}

const resolveColumnizationThreshold = ({ doc, vertical }) => {
    const fullWidthCharacterAdvancePx = Math.max(
        1,
        measureFullWidthCharacterAdvancePx({ doc, vertical })
    )
    const fullWidthCharacterThreshold = vertical
        ? COLUMNIZATION_CHARACTER_THRESHOLDS.verticalFullWidthCharacters
        : COLUMNIZATION_CHARACTER_THRESHOLDS.horizontalFullWidthCharacters
    const columnizationThresholdPx = Math.max(
        1,
        fullWidthCharacterAdvancePx * fullWidthCharacterThreshold
    )
    return {
        fullWidthCharacterAdvancePx,
        fullWidthCharacterThreshold,
        columnizationThresholdPx,
    }
}

// Chevron visual animations toggle (restored to enabled)
const CHEVRON_VISUALS_ENABLED = true;
// Preview chevrons during a swipe before navigation triggers
// Set to false to avoid mid-gesture state that previously required resets.
const CHEVRON_SWIPE_PREVIEW_ENABLED = false;

const logBug = (event, detail = {}) => {
    try {
        return globalThis.logBug?.(event, detail)
    } catch (_error) {
        return undefined
    }
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

const getLiveChunkPageCount = doc => {
    const count = doc?.querySelectorAll?.('.manabi-page')?.length ?? 0
    return count > 0 ? count : null
}

const trackingSizeCacheResolvers = new Map()
let trackingSizeCacheRequestCounter = 0

// General logger disabled for noise reduction
const logEBook = () => {}

const setSameDocumentHostTurnDiagnostics = detail => {
    try {
        globalThis.manabiSameDocumentHostTurnDiagnostics = {
            ...(globalThis.manabiSameDocumentHostTurnDiagnostics || {}),
            ...detail,
        }
    } catch (_error) {}
}

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

const MANABI_SAME_DOCUMENT_RENDERER_ENABLED = true

const applyVerticalWritingClass = (doc, isVertical) => {
    const enable = !!isVertical
    try { doc?.body?.classList?.toggle('reader-vertical-writing', enable) } catch (_) {}
}

const applyTategakiDisplayTransform = (doc, isVertical) => {
    if (!doc?.body) return
    try {
        globalThis.manabiApplyTategakiDisplayTransformToDocument?.(doc, {
            vertical: !!isVertical,
            isReaderMode: doc.body.classList.contains('readability-mode'),
            isEbook: true,
            root: doc.getElementById?.('reader-content') || doc.body,
        })
    } catch (_) {}
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

const waitForDocumentFontsReady = async (doc, {
    timeoutMs = 1200,
    reason = 'unspecified',
    sectionIndex = null,
} = {}) => {
    const fontsReady = doc?.fonts?.ready
    if (!fontsReady || typeof fontsReady.then !== 'function') return

    let timeoutID = null
    const timeoutPromise = new Promise(resolve => {
        timeoutID = setTimeout(() => {
            logEBookPerf('tracking-size-fonts-timeout', {
                reason,
                sectionIndex,
                timeoutMs,
            })
            resolve('timeout')
        }, timeoutMs)
    })

    try {
        await Promise.race([
            Promise.resolve(fontsReady).then(() => 'ready'),
            timeoutPromise,
        ])
    } catch (error) {
        logEBookPerf('tracking-size-fonts-error', {
            reason,
            sectionIndex,
            error: String(error),
        })
    } finally {
        if (timeoutID != null) clearTimeout(timeoutID)
    }
}


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

    // The same-document shell can keep unresolved font loads around longer than the
    // old iframe path. Do not let initial bake block indefinitely on that.
    await waitForDocumentFontsReady(doc, {
        timeoutMs: 1200,
        reason,
        sectionIndex,
    })

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
    _wait = ms => new Promise(resolve => setTimeout(resolve, ms))
    _debouncedExpand
    _inExpand = false
    _hasResizerObserverTriggered = false
    _lastResizerRect = null
    _lastBodyRect = null
    _lastContainerRect = null
    _resizeEventSeq = 0
    _resizeObserverFrame = null
    _pendingResizeRect = null
    _resizeObserver = null
    _styleCache = new WeakMap()
    _isCacheWarmer = false
    _pendingResizeAfterExpand = null
    _expandRetryScheduled = false
    _sameDocumentMode = MANABI_SAME_DOCUMENT_RENDERER_ENABLED
    _sameDocumentStyleNodes = []
    _sameDocumentAppliedBodyClasses = []
    _sameDocumentSourceURL = null
    _sameDocumentObservedElement = null
    cachedViewSize = null
    getLastBodyRect() {
        // Rounded body rect captured by the resize observer; avoids forcing layout reads elsewhere.
        return this._lastBodyRect
    }
    _handleResize(newSize) {
        if (!newSize) return
        const inExpand = this._inExpand || false
        // Keep resize lightweight: invalidate cached sizes and ask container to re-bake when enabled.
        if (this._isCacheWarmer) return
        this._lastBodyRect = newSize
        if (inExpand) {
            // Buffer the last resize that arrives while expand is running so we can replay it afterwards.
            this._pendingResizeAfterExpand = newSize
            logEBookResize('iframe-resize-buffered', {
                newSize,
                inExpand,
                isCacheWarmer: this._isCacheWarmer,
            })
            console.log('[paginator] handleResize buffered during expand', { newSize, inExpand })
            return
        }
        logEBookResize('iframe-resize-apply', {
            newSize,
            inExpand,
            isCacheWarmer: this._isCacheWarmer,
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
    _element = document.createElement('div')
    _iframe = document.createElement('iframe')
    _iframeShownForBake = false
    _contentRange = document.createRange()
    _overlayer
    _vertical = null
    _verticalRTL = null
    _rtl = null
    _directionReadyResolve = null;
    _directionReady = new Promise(r => (this._directionReadyResolve = r));
    _column = true
    _size
    _lastElementStyleHeight = null
    _elementStyleObserver = null
    layout = {}
    constructor({
        container,
        onBeforeExpand,
        onExpand,
        isCacheWarmer
    }) {
        this.container = container
        this._isCacheWarmer = isCacheWarmer
        this._sameDocumentMode = MANABI_SAME_DOCUMENT_RENDERER_ENABLED && !isCacheWarmer
        this._debouncedExpand = debounce(this.expand.bind(this), 999)
        this.onBeforeExpand = onBeforeExpand
        this.onExpand = onExpand
        if (this._sameDocumentMode) {
            this._iframe = document.createElement('div')
        }
        //        this._iframe.setAttribute('part', 'filter')
        this._element.append(this._iframe)
        Object.assign(this._element.style, {
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
        if (this._sameDocumentMode) {
            this._element.style.justifyContent = 'flex-start'
            this._element.style.alignItems = 'flex-start'
        }
        // Watch for unexpected inline height mutations on the view wrapper, which can cause page spikes.
        this._lastElementStyleHeight = this._element.style.height || null
        this._elementStyleObserver = new MutationObserver(mutations => {
            for (const m of mutations) {
                if (m.attributeName !== 'style') continue
                const current = this._element.style.height || null
                if (current === this._lastElementStyleHeight) continue
                const prevNumeric = parseFloat(this._lastElementStyleHeight ?? 'NaN')
                const currentNumeric = parseFloat(current ?? 'NaN')
                const isSpike = Number.isFinite(currentNumeric) && currentNumeric > 4000
                if (isSpike || current !== this._lastElementStyleHeight) {
                    logEBookPageNumLimited('element-style-height', {
                        previous: this._lastElementStyleHeight,
                        next: current,
                        isSpike,
                    })
                }
                this._lastElementStyleHeight = current
            }
        })
        try {
            this._elementStyleObserver.observe(this._element, { attributes: true, attributeFilter: ['style'] })
        } catch (_) {}
        Object.assign(this._iframe.style, {
            overflow: 'hidden',
            border: '0',
            //            display: 'none',
            display: 'block',
            width: '100%',
            height: '100%',
        })
        if (this._sameDocumentMode) {
            this._iframe.id = 'manabi-same-document-mount'
            this._iframe.className = 'manabi-same-document-mount'
            this._iframe.style.position = 'relative'
            this._iframe.style.boxSizing = 'border-box'
        } else {
            // `allow-scripts` is needed for events because of WebKit bug
            // https://bugs.webkit.org/show_bug.cgi?id=218086
            //        this._iframe.setAttribute('sandbox', 'allow-scripts allow-same-origin allow-popups allow-downloads')
            //this._iframe.setAttribute('sandbox', 'allow-same-origin allow-scripts') // Breaks font-src data: blobs...
            this._iframe.setAttribute('scrolling', 'no')
        }

        this._resizeObserver = new ResizeObserver(entries => {
            if (this._isCacheWarmer) return;
            const entry = entries[0];
            if (!entry) return;
            const rect = entry.contentRect;
            this._pendingResizeRect = {
                width: Math.round(rect.width),
                height: Math.round(rect.height),
                top: Math.round(rect.top),
                left: Math.round(rect.left),
            }
            if (this._resizeObserverFrame !== null) cancelAnimationFrame(this._resizeObserverFrame)
            this._resizeObserverFrame = requestAnimationFrame(() => {
                this._resizeObserverFrame = null
                this._handleResize(this._pendingResizeRect)
            })
        })
    }

    revealIframeForBake(reason) {
        if (this._iframeShownForBake) return
        if (this._iframe?.style?.display === 'none') {
            this._iframe.style.display = 'block'
            this._iframeShownForBake = true
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
        return this._element
    }
    reconcileSameDocumentExpandedWidth() {
        if (!this._sameDocumentMode || !this._column || !Number.isFinite(this._size) || this._size <= 0) {
            return null
        }
        try {
            const liveRoot = document?.getElementById?.('reader-content')?.querySelector?.('.manabi-page-root') || null
            const livePages = Array.from(liveRoot?.querySelectorAll?.(':scope > .manabi-page') || [])
            const livePageCount = livePages.length
            const livePageExtent = livePages.reduce((max, node) => {
                try {
                    const left = Number.isFinite(node?.offsetLeft)
                        ? node.offsetLeft
                        : (node?.getBoundingClientRect?.().left || 0)
                    const width = Number.isFinite(node?.offsetWidth) && node.offsetWidth > 0
                        ? node.offsetWidth
                        : (node?.getBoundingClientRect?.().width || 0)
                    return Math.max(max, left + width)
                } catch (_error) {
                    return max
                }
            }, 0)
            const layoutController = document?.defaultView?.manabiEbookSectionLayoutController
            const layoutPageCount = Math.max(
                1,
                livePageCount,
                Number.parseInt(String(layoutController?.pageCount?.() ?? 1), 10) || 1,
                this._getSameDocumentResolvedPageCountSync() || 1
            )
            const side = this._vertical ? 'height' : 'width'
            const otherSide = this._vertical ? 'width' : 'height'
            const layoutExpandedSize = Math.max(
                this._size,
                livePageExtent,
                layoutPageCount * this._size,
            )
            this._iframe.style[side] = `${layoutExpandedSize}px`
            this._element.style[side] = `${layoutExpandedSize + this._size * 2}px`
            this._container.style[side] = `${layoutExpandedSize + this._size * 2}px`
            this._iframe.style[otherSide] = '100%'
            this._element.style[otherSide] = '100%'
            this._container.style[otherSide] = '100%'
            logEBookPageNumLimited('expand:same-document-reconcile', {
                side,
                size: this._size,
                layoutPageCount,
                livePageCount,
                livePageExtent,
                layoutExpandedSize,
                iframe: this._iframe?.style?.[side] || null,
                element: this._element?.style?.[side] || null,
                container: this._container?.style?.[side] || null,
            })
            return {
                layoutPageCount,
                layoutExpandedSize,
            }
        } catch (_error) {
            return null
        }
    }
    get document() {
        if (this._sameDocumentMode) return document
        return this._iframe.contentDocument
    }
    _getContentRoot() {
        if (this._sameDocumentMode) {
            return this._iframe.querySelector('#reader-content') || this._iframe
        }
        return this.document?.getElementById?.('reader-content') || this.document?.body || null
    }
    _removeSameDocumentStyles() {
        for (const node of this._sameDocumentStyleNodes) node?.remove?.()
        this._sameDocumentStyleNodes = []
    }
    _clearSameDocumentBodyState() {
        if (document?.body) {
            for (const className of this._sameDocumentAppliedBodyClasses) {
                document.body.classList.remove(className)
            }
            document.body.removeAttribute('data-is-ebook')
        }
        this._sameDocumentAppliedBodyClasses = []
    }
    _resetSameDocumentState() {
        this._removeSameDocumentStyles()
        this._clearSameDocumentBodyState()
        this._iframe.replaceChildren()
        this._sameDocumentSourceURL = null
    }
    async _loadSameDocument(src, afterLoad, beforeRender, sectionIndex = null, sectionLocation = null) {
        this._iframeShownForBake = true
        this._sameDocumentSourceURL = src
        this._vertical = this._verticalRTL = this._rtl = null;
        this._directionReady = new Promise(r => (this._directionReadyResolve = r));
        this._resetSameDocumentState()
        this._sameDocumentSourceURL = src

        const html = await fetch(src).then(r => r.text())
        const sourceDoc = new DOMParser().parseFromString(html, 'text/html')

        for (const node of Array.from(sourceDoc.head?.children || [])) {
            const tagName = node.tagName?.toLowerCase?.()
            if (tagName !== 'style' && tagName !== 'link') continue
            if (tagName === 'link' && node.getAttribute('rel') !== 'stylesheet') continue
            const clone = node.cloneNode(true)
            clone.dataset.manabiSameDocumentSectionStyle = 'true'
            document.head.append(clone)
            this._sameDocumentStyleNodes.push(clone)
        }

        if (document?.body) {
            document.body.dataset.isEbook = sourceDoc.body?.dataset?.isEbook || 'true'
            const applied = Array.from(sourceDoc.body?.classList || []).filter(Boolean)
            for (const className of applied) document.body.classList.add(className)
            this._sameDocumentAppliedBodyClasses = applied
        }

        for (const child of Array.from(sourceDoc.body?.childNodes || [])) {
            this._iframe.append(child.cloneNode(true))
        }
        if (!this._iframe.querySelector('#reader-content')) {
            const readerContent = document.createElement('div')
            readerContent.id = 'reader-content'
            const page = document.createElement('div')
            page.className = 'page'
            const article = document.createElement('article')
            while (this._iframe.firstChild) {
                article.append(this._iframe.firstChild)
            }
            page.append(article)
            readerContent.append(page)
            this._iframe.append(readerContent)
        }
        try {
            document.defaultView.manabiCurrentContentURL = sectionLocation || src
        } catch (_error) {}

        await afterLoad?.(document)
        Promise.resolve().then(() => globalThis.manabiWaitForFontCSS?.()).catch(() => {})
        Promise.resolve().then(() => globalThis.manabiEnsureCustomFonts?.(document)).catch(() => {})

        const writingDirectionOverride = globalThis.manabiEbookWritingDirection || 'original'
        const sourceDir = sourceDoc.body?.getAttribute?.('dir')
            || sourceDoc.documentElement?.getAttribute?.('dir')
            || 'ltr'
        this._rtl = sourceDir === 'rtl'
        if (writingDirectionOverride === 'vertical') {
            this._vertical = true
            this._verticalRTL = true
        } else {
            this._vertical = false
            this._verticalRTL = false
        }
        applyVerticalWritingClass(document, this._vertical)
        applyTategakiDisplayTransform(document, this._vertical)
        globalThis.manabiTrackingVertical = this._vertical
        globalThis.manabiTrackingVerticalRTL = this._verticalRTL
        globalThis.manabiTrackingRTL = this._rtl
        globalThis.manabiTrackingWritingMode = this._vertical
            ? (this._verticalRTL ? 'vertical-rl' : 'vertical-lr')
            : (this._rtl ? 'horizontal-rtl' : 'horizontal-ltr')
        this._directionReadyResolve?.();

        const contentRoot = this._getContentRoot()
        if (contentRoot) {
            this._contentRange.selectNodeContents(contentRoot)
        }

        const layout = await beforeRender?.({
            vertical: this._vertical,
            rtl: this._rtl,
        })

        revealDocumentContentForBake(document)
        this._sameDocumentObservedElement = contentRoot || this._iframe
        if (this._sameDocumentObservedElement) {
            this._resizeObserver.observe(this._sameDocumentObservedElement)
        }
        await this.container?.performInitialBakeFromView?.(sectionIndex ?? this.container?.currentIndex, layout)
    }
    async load(src, afterLoad, beforeRender, sectionIndex = null, sectionLocation = null) {
        if (typeof src !== 'string') throw new Error(`${src} is not string`)
        if (this._sameDocumentMode) {
            globalThis.manabiLoadEBookLastState = 'paginator-load-same-document-begin'
            return await this._loadSameDocument(src, afterLoad, beforeRender, sectionIndex, sectionLocation)
        }
        globalThis.manabiLoadEBookLastState = 'paginator-load-iframe-begin'
        this._iframeShownForBake = false
        // Reset direction flags and promise before loading a new section
        this._vertical = this._verticalRTL = this._rtl = null;
        this._directionReady = new Promise(r => (this._directionReadyResolve = r));
        // When size baking is enabled, keep the iframe hidden until we're ready to bake/reveal.
        if (MANABI_TRACKING_SIZE_BAKE_ENABLED) {
            this._iframe.style.display = 'none'
            logEBookPerf('iframe-display-set', { state: 'hidden-before-src', src })
        } else {
            this._iframe.style.display = 'block'
        }
        return new Promise(async (resolve) => {
            if (this._isCacheWarmer) {
                console.log("Don't create View for cache warmers")
                resolve()
            } else {
                this._iframe.addEventListener('load', async () => {
                    globalThis.manabiLoadEBookLastState = 'paginator-load-iframe-load-event'
                    try { await globalThis.manabiWaitForFontCSS?.() } catch {}
                    const doc = this.document

                    try { globalThis.manabiEnsureCustomFonts?.(doc) } catch {}

                    globalThis.manabiLoadEBookLastState = 'paginator-load-before-afterLoad'
                    await afterLoad?.(doc)
                    globalThis.manabiLoadEBookLastState = 'paginator-load-after-afterLoad'

                    //                    this._iframe.style.display = 'none'

                    const { bodylessStyle, bodylessDoc } = await getBodylessComputedStyle(doc)
                    const direction = await getDirection({ bodylessStyle, bodylessDoc });
                    this._vertical = direction.vertical;
                    this._verticalRTL = direction.verticalRTL;
                    this._rtl = direction.rtl;
                    applyVerticalWritingClass(doc, this._vertical)
                    applyTategakiDisplayTransform(doc, this._vertical)
                    globalThis.manabiTrackingVertical = this._vertical
                    globalThis.manabiTrackingVerticalRTL = this._verticalRTL
                    globalThis.manabiTrackingRTL = this._rtl
                    globalThis.manabiTrackingWritingMode = this._vertical
                        ? (this._verticalRTL ? 'vertical-rl' : 'vertical-lr')
                        : (this._rtl ? 'horizontal-rtl' : 'horizontal-ltr')
                    this._directionReadyResolve?.();

                    const contentRoot = this._getContentRoot() || doc.body
                    this._contentRange.selectNodeContents(contentRoot)

                    globalThis.manabiLoadEBookLastState = 'paginator-load-before-beforeRender'
                    const layout = await beforeRender?.({
                        vertical: this._vertical,
                        rtl: this._rtl,
                    })
                    globalThis.manabiLoadEBookLastState = 'paginator-load-after-beforeRender'

                    // Allow layout/expand only when we're ready to bake: reveal iframe + document, render without expanding, bake, then expand.
                    this.revealIframeForBake('initial-load')
                    revealDocumentContentForBake(doc)

                    // First bake happens before any expand/page sizing.
                    globalThis.manabiLoadEBookLastState = 'paginator-load-before-initial-bake'
                    await this.container?.performInitialBakeFromView?.(sectionIndex ?? this.container?.currentIndex, layout)
                    globalThis.manabiLoadEBookLastState = 'paginator-load-after-initial-bake'

                    this._sameDocumentObservedElement = doc.body
                    this._resizeObserver.observe(doc.body)

                    globalThis.manabiLoadEBookLastState = 'paginator-load-iframe-resolve'
                    resolve()
                }, {
                    once: true
                })
                globalThis.manabiLoadEBookLastState = 'paginator-load-iframe-set-src'
                this._iframe.src = src
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
            vertical: this._vertical,
            isCacheWarmer: this._isCacheWarmer,
        })
        logEBookPerf('EXPAND.render-start', {
            flow: layout.flow,
            skipExpand,
            source,
            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
            ready: this.container?.trackingSizeBakeReadyPublic ?? null,
            inExpand: this._inExpand || false,
        })
        layout.usePaginate = false // disable Paginate integration for now
        this._column = layout.flow !== 'scrolled'
        this.layout = layout

        applyVerticalWritingClass(this.document, this._vertical)
        applyTategakiDisplayTransform(this.document, this._vertical)

        if (this._column) {
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
            column: this._column,
            vertical: this._vertical,
        })
        logEBookPerf('EXPAND.render-complete', {
            flow: layout.flow,
            skipExpand,
            source,
            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
            ready: this.container?.trackingSizeBakeReadyPublic ?? null,
            inExpand: this._inExpand || false,
        })
    }
    async scrolled({
        gap,
        columnWidth,
        shouldColumnizeForThreshold = true
    }, { skipExpand = false } = {}) {
        await this._awaitDirection();
        const vertical = this._vertical
        const doc = this.document
        const layoutRoot = this._getContentRoot() || doc.documentElement
        const bottomMarginPx = CSS_DEFAULTS.bottomMarginPx;
        const constrainedSize = shouldColumnizeForThreshold
            ? `${columnWidth}px`
            : 'none'
        const margin = shouldColumnizeForThreshold ? 'auto' : '0'
        const padding = shouldColumnizeForThreshold
            ? (vertical ? `${gap}px 0` : `0 ${gap}px`)
            : '0'
        const effectiveGap = shouldColumnizeForThreshold ? `${gap}px` : '0px'
        logEBookPerf('EXPAND.scrolled-entry', {
            skipExpand,
            shouldColumnizeForThreshold,
            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
            ready: this.container?.trackingSizeBakeReadyPublic ?? null,
        })
        const layoutRootStyles = {
            'box-sizing': 'border-box',
            'padding': padding,
            //            border: `${gap}px solid transparent`,
            //            borderWidth: vertical ? `${gap}px 0` : `0 ${gap}px`,
            'column-width': 'auto',
            'height': 'auto',
            'width': 'auto',

            //            // columnize parity
            // columnGap: '0',
            '--paginator-column-gap': effectiveGap,
            'column-gap': effectiveGap,
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

            // columnize parity
            '--paginator-margin': `${bottomMarginPx}px`,
        }
        if (globalThis.manabiPageTurnInteractionDiagnostic !== true) {
            // This improves clipping in some cases, but it can also blank the
            // snapshot-visible page body on Apple platforms while layout data
            // still looks healthy. Keep it off in diagnostics until the visual
            // rendering path is proven stable.
            layoutRootStyles['-webkit-line-box-contain'] = 'block glyphs replaced'
        }
        setStylesImportant(layoutRoot, layoutRootStyles)
        // columnize parity
        setStylesImportant(this._getContentRoot() || doc.body, {
            [vertical ? 'max-height' : 'max-width']: constrainedSize,
            'margin': margin,
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
        await this._awaitDirection();
        //        console.log("columnize... await'd direction")
        const vertical = this._vertical
        this._size = vertical ? height : width
        logEBookPerf('EXPAND.columnize-entry', {
            skipExpand,
            size: this._size,
            width,
            height,
            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
            ready: this.container?.trackingSizeBakeReadyPublic ?? null,
        })
        //        console.log("columnize #size = ", this._size)

        const doc = this.document
        const layoutRoot = this._getContentRoot() || doc.documentElement
        const columnizeStyles = {
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
        }
        if (globalThis.manabiPageTurnInteractionDiagnostic !== true) {
            columnizeStyles['-webkit-line-box-contain'] = 'block glyphs replaced'
        }
        setStylesImportant(layoutRoot, columnizeStyles)
        const bottomMarginPx = CSS_DEFAULTS.bottomMarginPx;
        layoutRoot.style.setProperty('--paginator-margin', `${bottomMarginPx}px`)
        setStylesImportant(this._getContentRoot() || doc.body, {
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
        //            //            this._debouncedExpand()
        //        }
    }
    async _awaitDirection() {
        if (this._vertical === null) await this._directionReady;
    }
    async expand() {
        logEBookPerf('expand-request', {
            column: this._column,
            vertical: this._vertical,
            size: this._size,
            cacheWarmer: this._isCacheWarmer,
        })
        logEBookPerf('EXPAND.expand-entry', {
            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
            trackingReady: this.container?.trackingSizeBakeReadyPublic ?? null,
            pendingReason: this.container?.pendingTrackingSizeBakeReasonPublic ?? null,
            inExpand: this._inExpand || false,
        })
        logEBookPageNumLimited('expand:entry', {
            column: this._column,
            vertical: this._vertical,
            size: this._size,
            cacheWarmer: this._isCacheWarmer,
            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
            trackingReady: this.container?.trackingSizeBakeReadyPublic ?? null,
            pendingReason: this.container?.pendingTrackingSizeBakeReasonPublic ?? null,
            inExpand: this._inExpand || false,
        })
        // Reset per-expand retry state; invalid measurements schedule a single retry.
        this._expandRetryScheduled = false
        this._inExpand = true
        try {
            await this.onBeforeExpand()
        } catch (error) {
            this._inExpand = false
            throw error
        }
        //        console.log("expand...")
        return new Promise(resolve => {
            requestAnimationFrame(async () => {
                try {
                    //                console.log("expand... inside 0")
                    const documentElement = this._getContentRoot() || this.document?.documentElement
                    const side = this._vertical ? 'height' : 'width'
                    const otherSide = this._vertical ? 'width' : 'height'
                    const scrollProp = side === 'width' ? 'scrollWidth' : 'scrollHeight'
                    //                let contentSize = documentElement?.[scrollProp] ?? 0;

                    if (this._column) {
                        const contentRect = this._contentRange.getBoundingClientRect()
                        const rootRect = documentElement.getBoundingClientRect()
                        logEBookPerf('RECT.expand-content', {
                            contentRect: { width: contentRect?.width ?? null, height: contentRect?.height ?? null, left: contentRect?.left ?? null, right: contentRect?.right ?? null },
                            rootRect: { width: rootRect?.width ?? null, height: rootRect?.height ?? null, left: rootRect?.left ?? null, right: rootRect?.right ?? null },
                        })
                        // offset caused by column break at the start of the page
                        // which seem to be supported only by WebKit and only for horizontal writing
                        const contentStart = this._vertical ? 0
                            : this._rtl ? rootRect.right - contentRect.right : contentRect.left - rootRect.left
                        const contentRectSide = contentRect?.[side] ?? 0
                        const contentSize = contentStart + contentRectSide
                        const sizeValid = Number.isFinite(this._size) && this._size > 0
                        const contentRectValid = Number.isFinite(contentRectSide) && contentRectSide > 0
                        const contentSizeValid = Number.isFinite(contentSize) && contentSize > 0
                        const pageCount = (sizeValid && contentSizeValid)
                            ? Math.ceil(contentSize / this._size)
                            : null
                        const invalidMeasurement = !sizeValid || !contentRectValid || !contentSizeValid || !pageCount || pageCount <= 0
                        console.log('[paginator] expand measure', {
                            size: this._size,
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
                                size: this._size,
                                contentRectSide,
                                contentStart,
                                contentSize,
                                pageCount,
                            })
                            logEBookBake('expand:invalid-measurement', {
                                mode: 'column',
                                side,
                                size: this._size,
                                contentRectSide,
                                contentStart,
                                contentSize,
                                pageCount,
                                column: this._column,
                                vertical: this._vertical,
                                readyFlag: this.container?.trackingSizeBakeReadyPublic ?? null,
                                suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                            })
                            // Defer a retry so we don't lock in a bogus 0/1 page count; often fonts/images finish after this.
                            if (!this._expandRetryScheduled) {
                                this._expandRetryScheduled = true
                                requestAnimationFrame(() => {
                                    this._expandRetryScheduled = false
                                    if (!this._inExpand) this.expand().catch(() => {})
                                })
                            }
                            return
                        }
                        logEBookPerf('EXPAND.metrics', {
                            mode: 'column',
                            side,
                            size: this._size,
                            contentSize,
                            pageCount,
                            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                            ready: this.container?.trackingSizeBakeReadyPublic ?? null,
                        })
                        logEBookPageNumLimited('expand:metrics', {
                            mode: 'column',
                            side,
                            size: this._size,
                            contentSize,
                            pageCount,
                            expandedSize: pageCount * this._size,
                            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                            ready: this.container?.trackingSizeBakeReadyPublic ?? null,
                        })
                        const expandedSize = pageCount * this._size

                        this._element.style.padding = '0'
                        this._iframe.style[side] = `${expandedSize}px`
                        this._element.style[side] = `${expandedSize + this._size * 2}px`
                        this._iframe.style[otherSide] = '100%'
                        this._element.style[otherSide] = '100%'
                        if (documentElement) {
                            documentElement.style[side] = `${this._size}px`
                        }
                        if (this._overlayer) {
                            this._overlayer.element.style.margin = '0'
                            this._overlayer.element.style.left = this._vertical ? '0' : `${this._size}px`
                            this._overlayer.element.style.top = this._vertical ? `${this._size}px` : '0'
                            this._overlayer.element.style[side] = `${expandedSize}px`
                            this._overlayer.redraw()
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
                            size: this._size,
                            contentSize,
                            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                            ready: this.container?.trackingSizeBakeReadyPublic ?? null,
                        })
                        logEBookPageNumLimited('expand:metrics', {
                            mode: 'scrolled',
                            side,
                            size: this._size,
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
                        if (this._vertical) {
                            this._element.style.paddingLeft = paddingTop
                            this._element.style.paddingRight = paddingBottom
                            this._element.style.paddingTop = '0'
                            this._element.style.paddingBottom = '0'
                        } else {
                            this._element.style.paddingLeft = '0'
                            this._element.style.paddingRight = '0'
                            this._element.style.paddingTop = paddingTop
                            this._element.style.paddingBottom = paddingBottom
                        }
                        this._iframe.style[side] = `${expandedSize}px`
                        this._element.style[side] = `${expandedSize}px`
                        this._iframe.style[otherSide] = '100%'
                        this._element.style[otherSide] = '100%'
                        if (this._overlayer) {
                            if (this._vertical) {
                                this._overlayer.element.style.marginLeft = paddingTop
                                this._overlayer.element.style.marginRight = paddingBottom
                                this._overlayer.element.style.marginTop = '0'
                                this._overlayer.element.style.marginBottom = '0'
                            } else {
                                this._overlayer.element.style.marginLeft = '0'
                                this._overlayer.element.style.marginRight = '0'
                                this._overlayer.element.style.marginTop = paddingTop
                                this._overlayer.element.style.marginBottom = paddingBottom
                            }
                            this._overlayer.element.style.left = '0'
                            this._overlayer.element.style.top = '0'
                            this._overlayer.element.style[side] = `${expandedSize}px`
                            this._overlayer.redraw()
                        }
                    }
                    //                console.log("expand... call onexpand")
                    logEBookPerf('expand-before-onexpand', {
                        column: this._column,
                        vertical: this._vertical,
                        side,
                        expandedSize: this._iframe?.style?.[side] || null,
                    })
                    logEBookPageNumLimited('expand:set-styles', {
                        column: this._column,
                        vertical: this._vertical,
                        side,
                        iframe: this._iframe?.style?.[side] || null,
                        element: this._element?.style?.[side] || null,
                        otherSide,
                        iframeOther: this._iframe?.style?.[otherSide] || null,
                        elementOther: this._element?.style?.[otherSide] || null,
                    })
                await this.onExpand()
                    this.reconcileSameDocumentExpandedWidth()
                logEBookPerf('expand-complete', {
                    column: this._column,
                    vertical: this._vertical,
                    size: this._size,
                })
                logEBookPerf('EXPAND.expand-complete', {
                    suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                    trackingReady: this.container?.trackingSizeBakeReadyPublic ?? null,
                    pendingReason: this.container?.pendingTrackingSizeBakeReasonPublic ?? null,
                    inExpand: this._inExpand || false,
                })
                    logEBookPageNumLimited('expand:complete', {
                        column: this._column,
                        vertical: this._vertical,
                        size: this._size,
                        suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                        trackingReady: this.container?.trackingSizeBakeReadyPublic ?? null,
                        pendingReason: this.container?.pendingTrackingSizeBakeReasonPublic ?? null,
                    })
                    //                console.log("expand... call'd onexpand")
                } finally {
                    const bufferedResize = this._pendingResizeAfterExpand
                    this._pendingResizeAfterExpand = null
                    this._inExpand = false
                    if (bufferedResize) {
                        console.log('[paginator] expand: replay buffered resize after expand', bufferedResize)
                        this._handleResize(bufferedResize)
                    }
                    resolve()
                }
            })
        })
    }
    set overlayer(overlayer) {
        this._overlayer = overlayer
        if (overlayer?.element) {
            this._element.append(overlayer.element)
        }
    }
    get overlayer() {
        return this._overlayer
    }
    destroy() {
        if (this._sameDocumentObservedElement) {
            this._resizeObserver.unobserve(this._sameDocumentObservedElement)
            this._sameDocumentObservedElement = null
        } else if (this.document?.body) {
            this._resizeObserver.unobserve(this.document.body)
        }
        if (this._sameDocumentMode) {
            this._resetSameDocumentState()
        }
        //        if (this.document) this._mutationObserver.disconnect()
    }
}

// NOTE: everything here assumes the so-called "negative scroll type" for RTL
export class Paginator extends HTMLElement {
    static observedAttributes = [
        'flow', 'gap', 'marginTop', 'marginBottom',
        'max-inline-size', 'max-block-size', 'max-column-count',
    ]
    _logChevronDispatch(_event, _payload = {}) {}
    _emitChevronOpacity(detail, source) {
        if (!CHEVRON_VISUALS_ENABLED) return;
        const nextLeft = detail?.leftOpacity ?? null;
        const nextRight = detail?.rightOpacity ?? null;
        if (this._lastChevronEmit.left === nextLeft && this._lastChevronEmit.right === nextRight) {
            this._logChevronDispatch('sideNavChevronOpacity:ignoredDuplicate', {
                source: source ?? null,
                leftOpacity: nextLeft,
                rightOpacity: nextRight,
                bookDir: this.bookDir ?? null,
                rtl: this._rtl,
            });
            return;
        }
        this._lastChevronEmit = { left: nextLeft, right: nextRight };
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
            this._logChevronDispatch('sideNavChevronOpacity:emit', {
                source: payload?.source ?? null,
                leftOpacity: payload?.leftOpacity ?? null,
                rightOpacity: payload?.rightOpacity ?? null,
                bookDir: this.bookDir ?? null,
                rtl: this._rtl,
                touchTriggeredNav: this._touchTriggeredNav,
                touchHasShownChevron: this._touchHasShownChevron,
                maxLeft: this._maxChevronLeft,
                maxRight: this._maxChevronRight,
            });
        }
        this.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
            bubbles: true,
            composed: true,
            detail: payload,
        }));
    }
    _root = this.attachShadow({
        mode: 'closed'
    })
    _debouncedRender = debounce(() => {
        if (!this.layout) return
        // Explicit source so diagnostics can attribute resize-triggered renders.
        this.render(this.layout, { source: 'resize' })
    }, 333)
    _lastResizerRect = null
    _resizeObserverFrame = null
    _pendingResizeRect = null
    _resizeObserver = new ResizeObserver(entries => {
        if (this._isCacheWarmer) return;
        const entry = entries[0];
        if (!entry) return;
        const rect = entry.contentRect;
        this._pendingResizeRect = {
            width: Math.round(rect.width),
            height: Math.round(rect.height),
            top: Math.round(rect.top),
            left: Math.round(rect.left),
        }
        if (this._resizeObserverFrame !== null) cancelAnimationFrame(this._resizeObserverFrame)
        this._resizeObserverFrame = requestAnimationFrame(() => {
            this._resizeObserverFrame = null
            this._handleContainerResize(this._pendingResizeRect)
        })
    })
    _suppressBakeOnExpand = false
    _handleContainerResize(newSize) {
        if (!newSize) return
        const old = this._lastResizerRect
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

        this._lastResizerRect = newSize
        this._cachedSizes = null
        this._cachedStart = null

        logEBookResize('container-resize-change', {
            newSize,
            old,
        })

        this._debouncedRender();

        // Wait one frame to ensure the container size has settled before rebaking sizes.
        if (MANABI_TRACKING_SIZE_BAKING_OPTIMIZED && MANABI_TRACKING_SIZE_RESIZE_TRIGGERS_ENABLED) {
            requestAnimationFrame(() => {
                const r = this._container?.getBoundingClientRect?.()
                logEBookPerf('RECT.container-resize-check', {
                    rect: r ? {
                        width: Math.round(r.width),
                        height: Math.round(r.height),
                        top: Math.round(r.top),
                        left: Math.round(r.left),
                    } : null,
                    last: this._lastResizerRect,
                })
                if (!r) return
                const stable = {
                    width: Math.round(r.width),
                    height: Math.round(r.height),
                    top: Math.round(r.top),
                    left: Math.round(r.left),
                }
                const still =
                    stable.width === this._lastResizerRect?.width &&
                    stable.height === this._lastResizerRect?.height

                if (!still) {
                    logEBookResize('container-resize-unstable', {
                        stable,
                        last: this._lastResizerRect,
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
    _top
    _transitioning = false;
    //    #background
    _container
    _defaultContainer
    _header
    _footer
    _view
    _ebookSectionLayout = new EbookSectionLayout()
    _ebookLayoutEventTarget = null
    _vertical = null
    _verticalRTL = null
    _rtl = null
    _directionReadyResolve = null;
    _directionReady = new Promise(r => (this._directionReadyResolve = r));
    _column = true
    _topMargin = 0
    _bottomMargin = 0
    _index = -1
    _loadingReason = null
    _hasExpandedOnce = false
    _activeBakeCount = 0
    _sizeBakeDebounceTimer = null
    _sizeBakeDebounceArgs = null
    _trackingSizeBakeQueuedRect = null
    get currentIndex() { return this._index }
    _anchor = 0 // anchor view to a fraction (0-1), Range, or Element
    _justAnchored = false
    _isLoading = false
    _locked = false // while true, prevent any further navigation
    _lockTimestamp = 0
    _styles
    _styleMap = new WeakMap()
    _scrollBounds
    _touchState
    _touchScrolled
    _isCacheWarmer = false
    _prefetchTimer = null
    _prefetchCache = new Map()
    _schedulePrefetchLoad(index) {
        const start = () => this.sections[index].load().catch(() => { });
        const ric = globalThis.requestIdleCallback;
        const promise = typeof ric === 'function'
            ? new Promise(resolve => ric(() => resolve(start()), { timeout: 500 }))
            : new Promise(resolve => setTimeout(() => resolve(start()), 50));
        this._prefetchCache.set(index, promise);
    }
    _skipTouchEndOpacity = false
    _isAdjustingSelectionHandle = false
    _trackingGeometryRebakeTimer = null
    _trackingGeometryPendingReason = null
    _trackingGeometryPendingRestoreLocation = false
    _trackingGeometryBakeInFlight = null
    _trackingGeometryBakeNeedsRerun = false
    _trackingGeometryBakeQueuedRestoreLocation = false
    _trackingGeometryBakeQueuedReason = null
    _wheelArmed = true // Hysteresis-based horizontal wheel paging
    _scrolledToAnchorOnLoad = false
    _trackingSizeBakeTimer = null
    _trackingSizeBakeInFlight = null
    _trackingSizeBakeNeedsRerun = false
    _trackingSizeBakeQueuedReason = null
    _skipNextExpandBake = false
    requestTrackingSectionSizeBakeDebounced = (args) => {
        logEBookResize('size-bake-requested', {
            reason: args?.reason ?? 'unspecified',
            rectProvided: !!args?.rect,
        })
        if (this._sizeBakeDebounceTimer) {
            clearTimeout(this._sizeBakeDebounceTimer)
        }
        this._sizeBakeDebounceArgs = args
        this._sizeBakeDebounceTimer = setTimeout(() => {
            const pending = this._sizeBakeDebounceArgs
            this._sizeBakeDebounceTimer = null
            this._sizeBakeDebounceArgs = null
            logEBookResize('size-bake-debounced-fire', {
                reason: pending?.reason ?? 'unspecified',
                rectProvided: !!pending?.rect,
            })
            this.requestTrackingSectionSizeBake(pending)
        }, 240)
        return true
    }
    _trackingSizeBakeReady = false
    _trackingSizeLastObservedRect = null
    _pendingTrackingSizeBakeReason = null
    _lastTrackingSizeBakedRect = null
    _relocateGeneration = 0

    // Expose selected private state for logging/debug from View.
    get trackingSizeBakeReadyPublic() { return this._trackingSizeBakeReady }
    get suppressBakeOnExpandPublic() { return this._suppressBakeOnExpand }
    get pendingTrackingSizeBakeReasonPublic() { return this._pendingTrackingSizeBakeReason }

    _cachedSizes = null
    _cachedStart = null

    _cachedSentinelDoc = null
    _cachedSentinelElements = []
    _cachedTrackingSections = []
    _cachedTrackingContainer = null
    _sentinelGroups = []
    _sentinelGroupsDoc = null
    _sentinelGroupsTotal = 0
    _sentinelGroupSize = 50
    _visibleSentinelElements = new Set()
    _sentinelElementIndex = new WeakMap()
    _activeSentinelGroupRange = {
        start: null,
        end: null,
    }
    _sentinelsInitialized = false
    _hasSentinels = false
    _lastSizesSnapshot = null
    _lastViewSizeSnapshot = null

    _elementVisibilityObserver = null
    _elementMutationObserver = null
    _sameDocumentViewport = null
    _sameDocumentMode = MANABI_SAME_DOCUMENT_RENDERER_ENABLED
    _sameDocumentCurrentPageIndex = 0

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
        this._root.innerHTML = `<style>
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
                contain: none;
        
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

                contain: none;
                will-change: auto;
                transform: none;
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

        this._top = this._root.getElementById('top')
        //        this._background = this._root.getElementById('background')
        this._container = this._root.getElementById('container')
        this._defaultContainer = this._container
        this._header = this._root.getElementById('header')
        this._footer = this._root.getElementById('footer')

        this._resizeObserver.observe(this._container)
        this._attachContainerListeners(this._container)
    }
    _attachContainerListeners(container) {
        if (!container || container.dataset.manabiPaginatorListenersAttached === 'true') return
        container.dataset.manabiPaginatorListenersAttached = 'true'
        container.addEventListener('scroll', () => this.dispatchEvent(new Event('scroll')))

        container.addEventListener('scroll', debounce(async () => {
            if (this._view?.isLoading) return;
            if (this.scrolled && !this._isCacheWarmer) {
                const range = await this._getVisibleRange();
                const index = this._index;
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

        container.addEventListener('scroll', debounce(async () => {
            if (this.scrolled) {
                if (this._justAnchored) {
                    this._justAnchored = false
                } else {
                    await this._afterScroll('scroll')
                }
            }
        }, 450))
    }
    _ensureSameDocumentViewport() {
        if (!this._sameDocumentMode || this._isCacheWarmer) return
        if (this._sameDocumentViewport) return
        const viewportHost = document.getElementById('reader-stage') || document.body
        const viewport = document.createElement('div')
        viewport.id = 'manabi-same-document-viewport'
        Object.assign(viewport.style, {
            position: viewportHost?.id === 'reader-stage' ? 'absolute' : 'fixed',
            inset: '0',
            overflow: 'hidden',
            zIndex: '2',
            pointerEvents: 'auto',
            boxSizing: 'border-box',
            background: 'transparent',
        })
        const container = document.createElement('div')
        container.id = 'manabi-same-document-container'
        Object.assign(container.style, {
            position: 'absolute',
            inset: '0',
            overflow: 'hidden',
            boxSizing: 'border-box',
            background: 'transparent',
        })
        // Same-document page roots encode progression explicitly. Keep the outer
        // viewport/container in physical LTR coordinates so WebKit doesn't mirror
        // the huge mounted strip offscreen for RTL books.
        viewport.style.direction = 'ltr'
        container.style.direction = 'ltr'
        viewport.append(container)
        viewportHost.append(viewport)
        this._resizeObserver.unobserve(this._container)
        this._sameDocumentViewport = viewport
        this._container = container
        this._attachContainerListeners(this._container)
        this._resizeObserver.observe(this._container)
        this._top.style.display = 'none'
    }
    _teardownSameDocumentViewport() {
        if (!this._sameDocumentViewport) return
        this._resizeObserver.unobserve(this._container)
        this._sameDocumentViewport.remove()
        this._sameDocumentViewport = null
        this._container = this._defaultContainer
        this._top.style.display = ''
        this._attachContainerListeners(this._container)
        this._resizeObserver.observe(this._container)
    }

    // NOTE: In this foliate-js fork, currently paginator can only open a book once
    open(book, isCacheWarmer) {
        // hide the view until final relocate needs
        this.style.display = 'none'

        this._isCacheWarmer = isCacheWarmer
        this._sameDocumentMode = MANABI_SAME_DOCUMENT_RENDERER_ENABLED && !isCacheWarmer
        if (this._sameDocumentMode) {
            this._ensureSameDocumentViewport()
        } else {
            this._teardownSameDocumentViewport()
        }
        this.bookDir = book.dir
        this.sections = book.sections

        // Keep chevron emitter state aligned with any external resets
        document.removeEventListener('resetSideNavChevrons', this._handleChevronResetEvent);
        document.addEventListener('resetSideNavChevrons', this._handleChevronResetEvent);

        if (!this._isCacheWarmer) {
            const opts = {
                passive: false
            }
            this.addEventListener('touchstart', this._onTouchStart.bind(this), opts)
            this.addEventListener('touchmove', this._onTouchMove.bind(this), opts)
            this.addEventListener('touchend', this._onTouchEnd.bind(this))
            this.addEventListener('touchcancel', this._onTouchCancel.bind(this))
            this.addEventListener('load', ({
                detail: {
                    doc
                }
            }) => {
                doc.addEventListener('touchstart', this._onTouchStart.bind(this), opts)
                doc.addEventListener('touchmove', this._onTouchMove.bind(this), opts)
                doc.addEventListener('touchend', this._onTouchEnd.bind(this))
                doc.addEventListener('touchcancel', this._onTouchCancel.bind(this))
            })
            this.addEventListener('wheel', this._onWheel.bind(this), opts);
        }
    }
    setSideNavWidth(widthPx) {
        this._top?.style?.setProperty('--side-nav-width', typeof widthPx === 'number' ? `${widthPx}px` : widthPx);
    }
    _createView() {
        this._cancelTrackingGeometryBakeSchedule()
        this._resetTrackingSectionSizeState()
        this._hasExpandedOnce = false
        if (this._view) {
            this._view.destroy()
            this._container.removeChild(this._view.element)
        }
        this._view = new View({
            container: this,
            onBeforeExpand: this._onBeforeExpand.bind(this),
            onExpand: this._onExpand.bind(this),
            isCacheWarmer: this._isCacheWarmer,
            //            onExpand: debounce(() => this._onExpand.bind(this), 500),
        })
        this._container.append(this._view.element)
        return this._view
    }
    _setLoading(isLoading, reason = 'unspecified') {
        const isExpand = reason === 'expand'
        if (isLoading && isExpand && this._hasExpandedOnce && !this._isLoading) {
            this._loadingReason = reason || this._loadingReason || 'unspecified'
            logEBookFlash('loading-skip', {
                sectionIndex: this._index,
                reason: this._loadingReason,
                hasExpandedOnce: this._hasExpandedOnce,
                isCacheWarmer: this._isCacheWarmer,
            })
            return
        }
        if (this._isLoading === isLoading) return
        this._isLoading = isLoading;
        this._loadingReason = reason || this._loadingReason || 'unspecified'
        if (isLoading) {
            this._top.classList.add('reader-loading');
            logEBookFlash('loading-start', {
                sectionIndex: this._index,
                reason: this._loadingReason,
            })
        } else {
            this._top.classList.remove('reader-loading');
            logEBookFlash('loading-stop', {
                sectionIndex: this._index,
                reason: this._loadingReason,
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
        if (reason === 'styles-applied' && !this._trackingSizeBakeReady) {
            logEBookPerf('tracking-size-bake-request', {
                reason,
                sectionIndex: sectionIndex ?? this._index,
                status: 'skip-not-ready-styles-applied'
            })
            logEBookResize('size-bake-skip', {
                reason,
                sectionIndex: sectionIndex ?? this._index,
                status: 'skip-not-ready-styles-applied',
                ready: this._trackingSizeBakeReady,
            })
            return false
        }
        const ctxBase = {
            reason,
            sectionIndex: sectionIndex ?? this._index,
            hasDoc: !!this._view?.document,
            ready: this._trackingSizeBakeReady,
            inFlight: !!this._trackingSizeBakeInFlight,
            pendingReason: this._pendingTrackingSizeBakeReason || null,
        }
        if (!MANABI_TRACKING_SIZE_BAKE_ENABLED) {
            logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'disabled' })
            this._setLoading(false, 'size-bake-disabled')
            return false
        }
        if (this._isCacheWarmer) return false
        if (!this._view?.document) {
            logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'no-document' })
            logEBookResize('size-bake-skip', { ...ctxBase, status: 'no-document' })
            this._pendingTrackingSizeBakeReason = reason
            return false
        }
        if (!this._trackingSizeBakeReady) {
            logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'not-ready' })
            logEBookResize('size-bake-skip', { ...ctxBase, status: 'not-ready' })
            this._pendingTrackingSizeBakeReason = reason
            return false
        }

        if (rect) {
            const last = this._trackingSizeLastObservedRect
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
            this._trackingSizeLastObservedRect = rect
        } else {
            // Only respond to rects captured elsewhere (e.g., resize observer cache); avoid new layout reads here.
            const cachedBodyRect = this._view?.getLastBodyRect?.()
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
            const lastBaked = this._lastTrackingSizeBakedRect
            if (lastBaked &&
                derived.width === lastBaked.width &&
                derived.height === lastBaked.height &&
                derived.top === lastBaked.top &&
                derived.left === lastBaked.left) {
                logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'unchanged-derived' })
                logEBookResize('size-bake-skip', { ...ctxBase, status: 'unchanged-derived', derived })
                return false
            }
            this._trackingSizeLastObservedRect = derived
        }

        if (this._trackingSizeBakeInFlight) {
            const sameQueuedReason = this._trackingSizeBakeQueuedReason === reason
            const sameQueuedRect = rect && this._trackingSizeBakeQueuedRect &&
                rect.width === this._trackingSizeBakeQueuedRect.width &&
                rect.height === this._trackingSizeBakeQueuedRect.height &&
                rect.top === this._trackingSizeBakeQueuedRect.top &&
                rect.left === this._trackingSizeBakeQueuedRect.left

            if (sameQueuedReason && sameQueuedRect) {
                logEBookResize('size-bake-queued-skip-same', { ...ctxBase, rectProvided: !!rect })
                return true
            }

            this._trackingSizeBakeNeedsRerun = true
            this._trackingSizeBakeQueuedReason = reason
            this._trackingSizeBakeQueuedRect = rect || this._trackingSizeBakeQueuedRect
            logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'queued-rerun' })
            logEBookPageNumLimited('bake:request', { ...ctxBase, status: 'queued-rerun' })
            logEBookResize('size-bake-queued-rerun', { ...ctxBase, rectProvided: !!rect, rect })
            return true
        }

        this._trackingSizeBakeQueuedReason = null
        this._trackingSizeBakeNeedsRerun = false
        this._trackingSizeBakeQueuedRect = null

        logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'start' })
        logEBookPageNumLimited('bake:request', { ...ctxBase, status: 'start', rectProvided: !!rect })
        logEBookResize('size-bake-start', { ...ctxBase, rectProvided: !!rect, rect })
        this._trackingSizeBakeInFlight = this._performTrackingSectionSizeBake({
            reason,
            sectionIndex: sectionIndex ?? this._index,
            skipPostBakeRefresh,
        }).catch(error => {
            // swallow bake errors after reporting if needed
            console.error('tracking size bake error', error)
            logEBookPageNumLimited('bake:error', { ...ctxBase, error: String(error) })
            logEBookResize('size-bake-error', { ...ctxBase, error: String(error) })
        }).finally(() => {
            this._trackingSizeBakeInFlight = null
            if (this._trackingSizeBakeNeedsRerun) {
                const queuedReason = this._trackingSizeBakeQueuedReason || 'rerun'
                this._trackingSizeBakeNeedsRerun = false
                this.requestTrackingSectionSizeBake({ reason: queuedReason })
            }
        })

        return true
    }

    _resetTrackingSectionSizeState() {
        if (this._trackingSizeBakeTimer) {
            clearTimeout(this._trackingSizeBakeTimer)
            this._trackingSizeBakeTimer = null
        }
        this._trackingSizeBakeInFlight = null
        this._trackingSizeBakeNeedsRerun = false
        this._trackingSizeBakeQueuedReason = null
        this._trackingSizeLastObservedRect = null
        this._pendingTrackingSizeBakeReason = null
        this._trackingSizeBakeReady = false
        this._lastTrackingSizeBakedRect = null
        this._skipNextExpandBake = false
        this._loadingReason = null

        this._cachedSentinelDoc = null
        this._cachedSentinelElements = []
        this._cachedTrackingSections = []

        logEBookPageNumLimited('bake:reset-state', {
            sectionIndex: this._index ?? null,
        })
    }

    _revealPreBakeContent() {
        if (!this._view?.document) return
        revealDocumentContentForBake(this._view.document)
        logEBookPageNumLimited('bake:reveal-prebake-content', {
            sectionIndex: this._index ?? null,
        })
    }

    // Public helper for View to force an initial size bake before first expand.
    async performInitialBakeFromView(sectionIndex, layout) {
        if (!MANABI_TRACKING_SIZE_BAKE_ENABLED) {
            // When baking is off, we still need a first render+expand so pagination works.
            this._suppressBakeOnExpand = false
            this._trackingSizeBakeReady = true
            logEBookPageNumLimited('bake:initial:skipped', {
                sectionIndex,
                suppressBakeOnExpand: this._suppressBakeOnExpand,
                readyFlag: this._trackingSizeBakeReady,
            })
            await this._view?.render(layout, { source: 'initial-bake-disabled' })
            return
        }
        // Lock expands and reset readiness before pre-bake render.
        this._suppressBakeOnExpand = true
        this._trackingSizeBakeReady = false
        logEBookBake('initial-bake:start', {
            sectionIndex,
            suppressBakeOnExpand: this._suppressBakeOnExpand,
        })
        logEBookPageNumLimited('bake:initial:start', {
            sectionIndex,
            suppressBakeOnExpand: this._suppressBakeOnExpand,
            readyFlag: this._trackingSizeBakeReady,
        })

        // Apply layout styles (without expanding) so bake measures correct flow.
        await this._view?.render(layout, { skipExpand: true, source: 'initial-bake-pre-render' })
        logEBookPerf('tracking-size-bake-initial-from-view', {
            sectionIndex,
            ready: this._trackingSizeBakeReady,
        })
        const hasTrackingSections = !!this._view?.document?.querySelector?.(MANABI_TRACKING_SECTION_SELECTOR)
        if (!hasTrackingSections) {
            this._trackingSizeBakeReady = true
            this._suppressBakeOnExpand = false
            this._skipNextExpandBake = true
            logEBookBake('initial-bake:skip-no-tracking-sections', {
                sectionIndex,
                ready: this._trackingSizeBakeReady,
                suppressBakeOnExpand: this._suppressBakeOnExpand,
            })
            logEBookBake('initial-bake:done-no-tracking-sections', {
                sectionIndex,
                ready: this._trackingSizeBakeReady,
                suppressBakeOnExpand: this._suppressBakeOnExpand,
            })
            return
        }
        logEBookPerf('EXPAND.callsite', {
            source: 'initial-bake-start',
            suppressBakeOnExpand: this._suppressBakeOnExpand,
            ready: this._trackingSizeBakeReady,
        })
        try {
            await this._performTrackingSectionSizeBake({
                reason: 'initial-load',
                sectionIndex,
                skipPostBakeRefresh: true,
            })
            logEBookBake('initial-bake:after-perform', {
                sectionIndex,
                ready: this._trackingSizeBakeReady,
                suppressBakeOnExpand: this._suppressBakeOnExpand,
            })
        } finally {
            // Keep suppressBakeOnExpand true through the first post-bake render/expand
            // to avoid a redundant bake loop. It will be unset after that expand.
        }

        logEBookPerf('EXPAND.callsite', {
            source: 'initial-bake-after-bake',
            suppressBakeOnExpand: this._suppressBakeOnExpand,
            ready: this._trackingSizeBakeReady,
            bodyHidden: this.view?.document?.body?.classList?.contains?.(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS) ?? null,
        })

        // Post-bake render/expand with fresh measurements; allow expand to bake if needed.
        this._suppressBakeOnExpand = false
        this._skipNextExpandBake = true
        logEBookBake('initial-bake:post-render-begin', {
            sectionIndex,
            ready: this._trackingSizeBakeReady,
            suppressBakeOnExpand: this._suppressBakeOnExpand,
        })
        await this._view?.render(layout, { source: 'initial-bake-post-render' })
        logEBookPerf('EXPAND.callsite', {
            source: 'initial-bake-after-render',
            suppressBakeOnExpand: this._suppressBakeOnExpand,
            ready: this._trackingSizeBakeReady,
            bodyHidden: this.view?.document?.body?.classList?.contains?.(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS) ?? null,
        })
        logEBookPageNumLimited('bake:initial:done', {
            sectionIndex,
            ready: this._trackingSizeBakeReady,
            suppressBakeOnExpand: this._suppressBakeOnExpand,
        })
        logEBookBake('initial-bake:done', {
            sectionIndex,
            ready: this._trackingSizeBakeReady,
            suppressBakeOnExpand: this._suppressBakeOnExpand,
        })
    }

    async _performTrackingSectionSizeBake({
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
            this._setLoading(false, 'size-bake-disabled')
            return
        }
        const perfStart = performance?.now?.() ?? null
        const doc = this._view?.document
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
            this._setLoading(false, 'size-bake-no-doc')
            return
        }

        // Reveal iframe itself right as we begin baking; body stays hidden until reveal step below.
        this._view?.revealIframeForBake(reason)

        logEBookPerf('tracking-size-bake-begin', {
            reason,
            sectionIndex,
            isCacheWarmer: this._isCacheWarmer,
            hasDoc: !!doc,
        })
        logEBookPageNumLimited('bake:begin', {
            reason,
            sectionIndex,
            isCacheWarmer: this._isCacheWarmer,
            hasDoc: !!doc,
            readyFlag: this._trackingSizeBakeReady,
            pendingReason: this._pendingTrackingSizeBakeReason ?? null,
        })
        logEBookBake('bake:begin', {
            reason,
            sectionIndex,
            isCacheWarmer: this._isCacheWarmer,
            readyFlag: this._trackingSizeBakeReady,
            pendingReason: this._pendingTrackingSizeBakeReason ?? null,
        })
        logEBookFlash('size-bake-begin', {
            sectionIndex: sectionIndex ?? this._index,
            reason,
            activeBakeCount: this._activeBakeCount,
            hasExpandedOnce: this._hasExpandedOnce,
            loadingReason: this._loadingReason,
            isLoading: this._isLoading,
        })

        const activeView = this._view

        this._activeBakeCount += 1
        if (this._activeBakeCount === 1) {
            const shouldShowLoading = !(this._hasExpandedOnce && reason !== 'initial-load')
            if (shouldShowLoading) {
                this._setLoading(true, 'size-bake')
            } else {
                // Avoid reapplying the loading opacity mask on post-expand resize bakes; it causes a visible flash.
                logEBookFlash('loading-skip', {
                    sectionIndex: sectionIndex ?? this._index,
                    reason: 'size-bake',
                    bakeReason: reason,
                    hasExpandedOnce: this._hasExpandedOnce,
                    isCacheWarmer: this._isCacheWarmer,
                })
            }
        }
        hideDocumentContentForPreBake(doc)
        this._trackingSizeBakeReady = false
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
                vertical: this._vertical,
                reason,
                sectionIndex,
                bookId: this.bookDir,
                sectionHref: this.sections?.[this._index]?.href || this.sections?.[this._index]?.url || null,
            })
            try {
                await this._getSentinelVisibilities()
            } catch (error) {
            }
            const cachedBodyRect = this._view?.getLastBodyRect?.()
            if (cachedBodyRect) {
                this._lastTrackingSizeBakedRect = {
                    width: Math.round(cachedBodyRect.width),
                    height: Math.round(cachedBodyRect.height),
                    top: Math.round(cachedBodyRect.top),
                    left: Math.round(cachedBodyRect.left),
                }
            logEBookPageNumLimited('bake:last-baked-rect', {
                sectionIndex,
                rect: this._lastTrackingSizeBakedRect,
            })
        }

        // Clear any queued rect once a bake starts; new requests will set it again if needed.
        this._trackingSizeBakeQueuedRect = null

            // After bake completes, refresh layout & relocate once the full layout is known.
            // Guard against races where the user navigated away.
            if (!skipPostBakeRefresh && !this._isCacheWarmer && this._view === activeView && sectionIndex === this._index) {
                try {
                    // Re-render (columnize + expand) with the newly baked sizes without
                    // kicking off another bake loop from onExpand.
                    logEBookPerf('EXPAND.callsite', {
                        source: 'post-bake-refresh',
                        suppressBakeOnExpand: this._suppressBakeOnExpand,
                        ready: this._trackingSizeBakeReady,
                    })
                    this._suppressBakeOnExpand = true
                    if (typeof this.render === 'function') {
                        await this.render(this.layout, { source: 'post-bake-refresh' })
                    } else {
                    }
                    this._suppressBakeOnExpand = false

                    // Now recompute pagination/nav state.
                    await this._afterScroll('bake')
                } catch (error) {
                    this._suppressBakeOnExpand = false
                }
            }
        } finally {
            this._revealPreBakeContent()
            if (this._view === activeView) {
                this._activeBakeCount = Math.max(0, this._activeBakeCount - 1)
                const keepLoading =
                    this._activeBakeCount > 0 ||
                    !!this._sizeBakeDebounceTimer ||
                    !!this._trackingSizeBakeNeedsRerun

                if (keepLoading) {
                    logEBookFlash('loading-keep', {
                        sectionIndex: this._index,
                        reason: 'size-bake-pending',
                        activeBakeCount: this._activeBakeCount,
                        debouncePending: !!this._sizeBakeDebounceTimer,
                        rerunQueued: !!this._trackingSizeBakeNeedsRerun,
                    })
                } else {
                    this._setLoading(false, 'size-bake-complete')
                }
                logEBookFlash('size-bake-finish', {
                    sectionIndex: this._index,
                    reason,
                    keepLoading,
                    activeBakeCount: this._activeBakeCount,
                    debouncePending: !!this._sizeBakeDebounceTimer,
                    rerunQueued: !!this._trackingSizeBakeNeedsRerun,
                })
            }
            const durationMs = perfStart !== null && typeof performance !== 'undefined' && typeof performance.now === 'function'
                ? performance.now() - perfStart
                : null
            logEBookPerf('tracking-size-bake-complete', {
                reason,
                sectionIndex,
                durationMs,
                stillActiveView: this._view === activeView,
            })
            // Ready flag must be explicitly re-enabled by callers after bake completes.
            logEBookPerf('tracking-size-bake-ready-reset', {
                reason,
                sectionIndex,
                ready: this._trackingSizeBakeReady,
            })
            if (this._view === activeView) {
                this._trackingSizeBakeReady = true
                logEBookPerf('tracking-size-bake-ready-set', {
                    reason,
                    sectionIndex,
                    ready: this._trackingSizeBakeReady,
                })
                logEBookBake('bake:ready-set', {
                    reason,
                    sectionIndex,
                    durationMs,
                    stillActiveView: this._view === activeView,
                    lastBakedRect: this._lastTrackingSizeBakedRect ?? null,
                    lastObservedRect: this._trackingSizeLastObservedRect ?? null,
                })
                logEBookPageNumLimited('bake:ready-set', {
                    reason,
                    sectionIndex,
                    durationMs,
                    stillActiveView: this._view === activeView,
                    lastBakedRect: this._lastTrackingSizeBakedRect ?? null,
                    lastObservedRect: this._trackingSizeLastObservedRect ?? null,
                    readyFlag: this._trackingSizeBakeReady,
                })
            }
        }
    }

    _cancelTrackingGeometryBakeSchedule() {
        if (this._trackingGeometryRebakeTimer) {
            clearTimeout(this._trackingGeometryRebakeTimer)
            this._trackingGeometryRebakeTimer = null
        }
        this._trackingGeometryPendingReason = null
        this._trackingGeometryPendingRestoreLocation = false
    }

    async _performTrackingSectionGeometryBake({
        reason = 'unspecified',
        restoreLocation = false,
    } = {}) {
        // Geometry bake disabled
        return
    }

    async _safeCaptureVisibleRange() {
        try {
            const range = await this._getVisibleRange()
            if (!range) return null
            if (typeof range.cloneRange === 'function') return range.cloneRange()
            return range
        } catch (error) {
            // ignore capture errors
            return null
        }
    }
    async _calculateSentinelGroupSize(totalSentinels) {
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
    _resetSentinelObservers() {
        for (const group of this._sentinelGroups) {
            try {
                group?.observer?.disconnect?.()
            } catch {}
        }
        this._sentinelGroups = []
        this._sentinelGroupsDoc = null
        this._sentinelGroupsTotal = 0
        this._sentinelGroupSize = 50
        this._visibleSentinelElements = new Set()
        this._sentinelElementIndex = new WeakMap()
        this._activeSentinelGroupRange = {
            start: null,
            end: null,
        }
        this._sentinelsInitialized = false
    }
    _makeSentinelObserver(groupIndex) {
        return new IntersectionObserver(entries => {
            this._handleSentinelIntersections(groupIndex, entries)
        }, {
            root: this._container ?? null,
            rootMargin: `${MANABI_SENTINEL_ROOT_MARGIN_PX}px`,
            threshold: [0],
        })
    }
    _createSentinelGroup(groupIndex) {
        const visible = new Set()
        return {
            index: groupIndex,
            observer: null,
            elements: [],
            visible,
            startIndex: groupIndex * this._sentinelGroupSize,
            endIndex: (groupIndex * this._sentinelGroupSize) - 1,
            active: false,
        }
    }
    _handleSentinelIntersections(groupIndex, entries) {
        const group = this._sentinelGroups?.[groupIndex]
        if (!group) return
        for (const entry of entries || []) {
            const el = entry.target
            if (!el) continue
            const isVisible = entry.isIntersecting || (entry.intersectionRatio ?? 0) > 0
            if (isVisible) {
                group.visible.add(el)
                this._visibleSentinelElements.add(el)
            } else {
                group.visible.delete(el)
                this._visibleSentinelElements.delete(el)
            }
        }
    }
    _deactivateSentinelGroup(group) {
        if (!group || !group.active) return
        for (const el of group.elements) {
            try {
                group.observer?.unobserve?.(el)
            } catch {}
            group.visible.delete(el)
            this._visibleSentinelElements.delete(el)
        }
        group.active = false
    }
    _activateSentinelGroup(group) {
        if (!group || group.active) return
        if (!group.observer) {
            group.observer = this._makeSentinelObserver(group.index ?? 0)
        }
        for (const el of group.elements) {
            group.observer.observe(el)
        }
        group.active = true
    }
    _syncSentinelGroups(doc, sentinelElements, groupSize) {
        const total = sentinelElements?.length ?? 0
        this._hasSentinels = total > 0
        if (this._sentinelGroupsDoc !== doc || this._sentinelGroupsTotal !== total) {
            this._resetSentinelObservers()
            this._sentinelGroupsDoc = doc
            this._sentinelGroupsTotal = total
        }

        if (!Number.isFinite(groupSize) || groupSize <= 0) groupSize = 50
        this._sentinelGroupSize = groupSize

        const requiredGroups = Math.max(0, Math.ceil(total / this._sentinelGroupSize))
        while (this._sentinelGroups.length < requiredGroups) {
            this._sentinelGroups.push(this._createSentinelGroup(this._sentinelGroups.length))
        }
        while (this._sentinelGroups.length > requiredGroups) {
            const group = this._sentinelGroups.pop()
            try {
                group?.observer?.disconnect?.()
            } catch {}
        }

        for (let groupIndex = 0; groupIndex < requiredGroups; groupIndex++) {
            const start = groupIndex * this._sentinelGroupSize
            const end = Math.min(total, start + this._sentinelGroupSize)
            const slice = sentinelElements.slice(start, end)
            const group = this._sentinelGroups[groupIndex]

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
                    this._visibleSentinelElements.delete(el)
                }
                group.elements = slice
                group.visible.clear()
                group.active = false
            }

            group.startIndex = start
            group.endIndex = end - 1
            slice.forEach((el, idx) => this._sentinelElementIndex.set(el, start + idx))
        }
    }
    _updateSentinelGroupActivation(startGroup, endGroup) {
        if (!Array.isArray(this._sentinelGroups) || this._sentinelGroups.length === 0) return
        for (let i = 0; i < this._sentinelGroups.length; i++) {
            const group = this._sentinelGroups[i]
            const withinRange = startGroup !== null &&
                endGroup !== null &&
                i >= startGroup &&
                i <= endGroup
            if (withinRange) this._activateSentinelGroup(group)
            else this._deactivateSentinelGroup(group)
        }
        this._activeSentinelGroupRange = {
            start: startGroup,
            end: endGroup,
        }
    }
    _flushSentinelRecords(startGroup = 0, endGroup = this._sentinelGroups.length - 1) {
        if (!Array.isArray(this._sentinelGroups) || this._sentinelGroups.length === 0) return
        const start = Math.max(0, startGroup)
        const end = Math.min(this._sentinelGroups.length - 1, endGroup)
        for (let i = start; i <= end; i++) {
            const group = this._sentinelGroups[i]
            const records = group?.observer?.takeRecords?.() ?? []
            if (records.length) this._handleSentinelIntersections(i, records)
        }
    }
    _collectVisibleSentinelSnapshot() {
        if (!this._visibleSentinelElements || this._visibleSentinelElements.size === 0) {
            return {
                visibleIds: [],
                minIndex: null,
                maxIndex: null,
            }
        }
        const indexed = []
        let minIndex = null
        let maxIndex = null
        for (const el of this._visibleSentinelElements) {
            const idx = this._sentinelElementIndex.get(el)
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
    async _onBeforeExpand() {
//        console.log("#onBeforeExpand...", this.style.display)
        logEBookPerf('on-before-expand', {
            pendingBakeReason: this._pendingTrackingSizeBakeReason || null,
            vertical: this._vertical,
            column: this._column,
        })
        this._revealPreBakeContent()
        this._view.cachedViewSize = null;
        this._view.cachedSizes = null;
        this._cachedStart = null;
        this._setLoading(true, 'expand')
        this._cachedStart = null
        this._trackingSizeBakeReady = false
        this._trackingSizeLastObservedRect = null
    }
    async _onExpand() {
//        console.log("#onExpand...", this.style.display)
        this._view.cachedViewSize = null;
        this._view.cachedSizes = null;
        this._cachedStart = null;

        const layoutSync = await this._syncEbookSectionLayout({
            reason: 'expand',
        })

        if (this._scrolledToAnchorOnLoad) {
            // wait a frame to ensure layout has settled before scrolling
            await new Promise(resolve => requestAnimationFrame(resolve));
            await this._scrollToAnchor(layoutSync?.restoreAnchor ?? this._anchor);
        }

        this._trackingSizeBakeReady = true
        const pendingReason = this._pendingTrackingSizeBakeReason
        this._pendingTrackingSizeBakeReason = null

        this._hasExpandedOnce = true

        // Avoid clearing loading if a size-bake is currently driving the spinner; let bake completion stop it.
        if (!(this._isLoading && this._loadingReason === 'size-bake')) {
            this._setLoading(false, 'expand')
        }
        const skipNextExpandBake = this._skipNextExpandBake
        const shouldBake = !this._suppressBakeOnExpand && !skipNextExpandBake
        this._skipNextExpandBake = false
        logEBookPerf('on-expand', {
            pendingReason: pendingReason || null,
            suppressBake: this._suppressBakeOnExpand,
            skipNext: skipNextExpandBake,
            hasDoc: !!this._view?.document,
            vertical: this._vertical,
            column: this._column,
        })
        logEBookPageNumLimited('bake:on-expand', {
            sectionIndex: this._index ?? null,
            pendingReason: pendingReason || null,
            suppressBake: this._suppressBakeOnExpand,
            readyFlag: this._trackingSizeBakeReady,
            skipNext: skipNextExpandBake,
        })
        if (shouldBake) {
            this.requestTrackingSectionSizeBake({ reason: pendingReason || 'expand' })
        }
    }

    _getActiveEbookSectionLayout() {
        const doc = this._view?.document
        if (!(doc instanceof Document)) return null
        if (this.scrolled || doc.body?.dataset?.isEbook !== 'true') return null
        return this._ebookSectionLayout.getSourceDocument() ? this._ebookSectionLayout : null
    }

    _getLiveChunkPageCount() {
        const activeLayoutPageCount = this._getActiveEbookSectionLayout()?.pageCount?.()
        if (Number.isFinite(activeLayoutPageCount) && activeLayoutPageCount > 0) {
            return activeLayoutPageCount
        }
        const cachedLayoutPageCount = this._ebookSectionLayout?.pageCount?.()
        if (Number.isFinite(cachedLayoutPageCount) && cachedLayoutPageCount > 0) {
            return cachedLayoutPageCount
        }
        return getLiveChunkPageCount(this._view?.document)
    }

    _getSameDocumentLiveRoot() {
        const doc = this._view?.document
        if (!(doc instanceof Document)) return null
        const contentRoot = doc.getElementById?.('reader-content') || doc.body || null
        return contentRoot?.querySelector?.('.manabi-page-root') || null
    }

    _usesSameDocumentPagePositioningSync() {
        return !!this._sameDocumentMode && !this.scrolled && this._getSameDocumentLiveRoot() instanceof HTMLElement
    }

    _isSameDocumentVerticalAxisSync() {
        const layoutDiagnostics = this._ebookSectionLayout?.layoutDiagnostics?.() ?? null
        if (layoutDiagnostics?.vertical === true) return true
        if (layoutDiagnostics?.writingMode === 'vertical-rl' || layoutDiagnostics?.writingMode === 'vertical-lr') {
            return true
        }
        const doc = this._view?.document
        return doc?.body?.classList?.contains?.('reader-vertical-writing') === true
    }

    _getSameDocumentResolvedPageCountSync() {
        const livePageCount = this._getLiveChunkPageCount()
        const layoutPageRecordCount = this._ebookSectionLayout?.layoutDiagnostics?.()?.pageRecordCount
        const liveRoot = this._getSameDocumentLiveRoot()
        const domPageCount = liveRoot?.querySelectorAll?.(':scope > .manabi-page')?.length ?? 0
        return Math.max(
            0,
            Number.isFinite(livePageCount) ? livePageCount : 0,
            Number.isFinite(layoutPageRecordCount) ? layoutPageRecordCount : 0,
            domPageCount
        )
    }

    _getSameDocumentResolvedNavigationStateSync() {
        const layoutDiagnostics = this._ebookSectionLayout?.layoutDiagnostics?.() ?? null
        const liveRoot = this._getSameDocumentLiveRoot()
        const datasetPageIndex = Number.isFinite(Number.parseInt(liveRoot?.dataset?.manabiCurrentPageIndex ?? '', 10))
            ? Number.parseInt(liveRoot?.dataset?.manabiCurrentPageIndex ?? '', 10)
            : null
        const layoutPageIndex = Number.isFinite(layoutDiagnostics?.currentPageIndex)
            && layoutDiagnostics.currentPageIndex >= 0
            ? layoutDiagnostics.currentPageIndex
            : null
        const layoutPageCount = Number.isFinite(layoutDiagnostics?.pageRecordCount)
            ? layoutDiagnostics.pageRecordCount
            : (Number.isFinite(layoutDiagnostics?.pageCount) ? layoutDiagnostics.pageCount : null)
        const resolvedPageCount = Math.max(
            this._getSameDocumentResolvedPageCountSync(),
            Number.isFinite(layoutPageCount) ? layoutPageCount : 0
        )
        const sameDocumentPageIndex = Number.isFinite(this._sameDocumentCurrentPageIndex)
            && this._sameDocumentCurrentPageIndex >= 0
            ? this._sameDocumentCurrentPageIndex
            : null
        const preferredPageIndex = this._usesSameDocumentPagePositioningSync()
            ? (datasetPageIndex ?? sameDocumentPageIndex ?? layoutPageIndex)
            : (layoutPageIndex ?? datasetPageIndex ?? sameDocumentPageIndex)
        const resolvedPageIndex = this._getSameDocumentClampedPageIndexSync(
            preferredPageIndex,
            resolvedPageCount
        )
        return {
            pageIndex: resolvedPageIndex,
            pageCount: resolvedPageCount,
        }
    }

    async _getSameDocumentPreparedNavigationState(targetPageIndex, reason = 'same-document-navigation') {
        const target = Number.isFinite(targetPageIndex) ? Math.max(0, Math.floor(targetPageIndex)) : null
        const activeLayout = this._getActiveEbookSectionLayout()
        if (target != null && typeof activeLayout?.ensurePageBuilt === 'function') {
            try {
                activeLayout.ensurePageBuilt(target, { reason })
            } catch (_error) {}
        }
        let resolved = this._getSameDocumentResolvedNavigationStateSync()
        if (
            target != null
            && resolved.pageCount <= 1
            && typeof activeLayout?.layoutDiagnostics === 'function'
        ) {
            await nextFrame()
            resolved = this._getSameDocumentResolvedNavigationStateSync()
        }
        return resolved
    }

    async _getSameDocumentResolvedPageCount() {
        return this._getSameDocumentResolvedPageCountSync()
    }

    _getSameDocumentClampedPageIndexSync(pageIndex = this._sameDocumentCurrentPageIndex, resolvedPageCountOverride = null) {
        const pageCount = Number.isFinite(resolvedPageCountOverride)
            ? resolvedPageCountOverride
            : this._getSameDocumentResolvedPageCountSync()
        if (!(pageCount > 0)) return 0
        const numericPageIndex = Number.isFinite(pageIndex)
            ? Math.floor(pageIndex)
            : this._sameDocumentCurrentPageIndex
        return Math.max(0, Math.min(pageCount - 1, numericPageIndex))
    }

    async _getSameDocumentClampedPageIndex(pageIndex = this._sameDocumentCurrentPageIndex, resolvedPageCountOverride = null) {
        return this._getSameDocumentClampedPageIndexSync(pageIndex, resolvedPageCountOverride)
    }

    _applySameDocumentPagePositionSync(pageIndex, {
        reason = 'same-document',
        smooth = false,
        resolvedPageCountOverride = null,
    } = {}) {
        const liveRoot = this._getSameDocumentLiveRoot()
        if (!(liveRoot instanceof HTMLElement)) return false
        const activeLayout = this._getActiveEbookSectionLayout()
        const resolvedPageIndex = this._getSameDocumentClampedPageIndexSync(
            pageIndex,
            resolvedPageCountOverride
        )
        const targetPageNode = liveRoot.querySelector(`:scope > .manabi-page[data-manabi-page-index="${resolvedPageIndex}"]`)
            || liveRoot.querySelector(`.manabi-page[data-manabi-page-index="${resolvedPageIndex}"]`)
            || null
        const verticalAxis = this._isSameDocumentVerticalAxisSync()
        const fallbackPageSpan = verticalAxis
            ? (
                Number.isFinite(targetPageNode?.offsetHeight) && targetPageNode.offsetHeight > 0
                    ? targetPageNode.offsetHeight
                    : (liveRoot.firstElementChild?.getBoundingClientRect?.().height || this.getBoundingClientRect?.().height || 0)
            )
            : (
                Number.isFinite(targetPageNode?.offsetWidth) && targetPageNode.offsetWidth > 0
                    ? targetPageNode.offsetWidth
                    : (liveRoot.firstElementChild?.getBoundingClientRect?.().width || this.getBoundingClientRect?.().width || 0)
            )
        const fallbackOffset = resolvedPageIndex * fallbackPageSpan
        const targetOffset = verticalAxis
            ? (Number.isFinite(targetPageNode?.offsetTop) ? targetPageNode.offsetTop : fallbackOffset)
            : (Number.isFinite(targetPageNode?.offsetLeft) ? targetPageNode.offsetLeft : fallbackOffset)
        const sameDocumentContainer = document.getElementById('manabi-same-document-container')
        const sameDocumentViewport = document.getElementById('manabi-same-document-viewport')
        liveRoot.style.willChange = 'transform'
        liveRoot.style.transition = smooth ? 'transform 220ms ease-out' : 'none'
        liveRoot.style.transform = verticalAxis
            ? `translate3d(0, ${-targetOffset}px, 0)`
            : `translate3d(${-targetOffset}px, 0, 0)`
        liveRoot.dataset.manabiCurrentPageIndex = String(resolvedPageIndex)
        if (sameDocumentContainer instanceof HTMLElement) {
            if (verticalAxis) {
                sameDocumentContainer.scrollTop = targetOffset
            } else {
                sameDocumentContainer.scrollLeft = targetOffset
            }
        }
        if (sameDocumentViewport instanceof HTMLElement) {
            if (verticalAxis) {
                sameDocumentViewport.scrollTop = targetOffset
            } else {
                sameDocumentViewport.scrollLeft = targetOffset
            }
        }
        if (this._container instanceof HTMLElement) {
            if (verticalAxis) {
                this._container.scrollTop = targetOffset
            } else {
                this._container.scrollLeft = targetOffset
            }
        }
        this._sameDocumentCurrentPageIndex = resolvedPageIndex
        if (activeLayout && typeof activeLayout.setCurrentSourceAnchor === 'function') {
            try {
                const sourceAnchor = typeof activeLayout.sourceRangeForPage === 'function'
                    ? activeLayout.sourceRangeForPage(resolvedPageIndex)
                    : null
                if (sourceAnchor) {
                    activeLayout.setCurrentSourceAnchor(sourceAnchor)
                }
            } catch (_error) {}
        }
        setSameDocumentHostTurnDiagnostics({
            phase: 'applied-position',
            reason,
            targetPageIndex: resolvedPageIndex,
            targetOffset,
            axis: verticalAxis ? 'vertical' : 'horizontal',
            appliedTransform: liveRoot.style.transform,
            datasetCurrentPageIndex: liveRoot.dataset.manabiCurrentPageIndex ?? null,
        })
        logEBookPageNumLimited('same-document:set-page-position', {
            reason,
            smooth: !!smooth,
            targetPage: resolvedPageIndex,
            targetOffset,
            fallbackOffset,
            axis: verticalAxis ? 'vertical' : 'horizontal',
            livePageCount: this._getSameDocumentResolvedPageCountSync(),
        })
        return true
    }

    async _applySameDocumentPagePosition(pageIndex, {
        reason = 'same-document',
        smooth = false,
        resolvedPageCountOverride = null,
    } = {}) {
        return this._applySameDocumentPagePositionSync(pageIndex, {
            reason,
            smooth,
            resolvedPageCountOverride,
        })
    }

    async _captureEbookRebuildLocation() {
        const activeLayout = this._getActiveEbookSectionLayout()
        if (!activeLayout) return null
        return activeLayout.captureLocationForPage(await this.page())
    }

    _handleEbookLayoutComplete = async () => {
        if (this._ebookLayoutEventTarget !== this._view?.document?.defaultView) return
        if (this.scrolled || !this._view) return
        try {
            this._view.reconcileSameDocumentExpandedWidth?.()
            if (this._usesSameDocumentPagePositioningSync()) {
                await this._applySameDocumentPagePosition(this._sameDocumentCurrentPageIndex, {
                    reason: 'layout-complete',
                    smooth: false,
                })
            }
            await this._afterScroll('layout-complete')
        } catch (error) {
            console.error(error)
        }
    }

    _bindEbookLayoutEvents(doc) {
        const nextTarget = doc?.defaultView ?? null
        if (this._ebookLayoutEventTarget === nextTarget) return
        this._ebookLayoutEventTarget?.removeEventListener?.(
            'manabi-ebook-layout-complete',
            this._handleEbookLayoutComplete
        )
        this._ebookLayoutEventTarget = nextTarget
        this._ebookLayoutEventTarget?.addEventListener?.(
            'manabi-ebook-layout-complete',
            this._handleEbookLayoutComplete
        )
    }

    async _syncEbookSectionLayout({ reason = 'unknown', anchor = null } = {}) {
        const doc = this._view?.document
        if (!(doc instanceof Document)) {
            this._bindEbookLayoutEvents(null)
            this._ebookSectionLayout.destroy()
            return null
        }
        if (this.scrolled || doc.body?.dataset?.isEbook !== 'true') {
            this._bindEbookLayoutEvents(null)
            this._ebookSectionLayout.destroy()
            return null
        }
        this._ebookSectionLayout.attach(doc)
        this._bindEbookLayoutEvents(doc)
        const rebuildLocation = anchor == null
            ? await this._captureEbookRebuildLocation()
            : null
        const result = await this._ebookSectionLayout.build({
            reason,
            anchor: typeof anchor === 'function' ? null : anchor,
            anchorResolver: typeof anchor === 'function' ? anchor : null,
            location: rebuildLocation,
        })
        const restoreAnchor = rebuildLocation
            ? this._ebookSectionLayout.sourceRangeForLocation(rebuildLocation)
            : null
        return {
            result,
            restoreAnchor,
        }
    }

    _resolveAnchorAgainstActiveLayout(anchor) {
        if (typeof anchor !== 'function') return anchor
        const activeLayout = this._getActiveEbookSectionLayout()
        const sourceDoc = activeLayout?.getSourceDocument()
        const liveDoc = this._view?.document
        const preferredDoc = sourceDoc ?? liveDoc
        let resolvedAnchor = preferredDoc ? anchor(preferredDoc) : anchor
        if (resolvedAnchor == null && sourceDoc && liveDoc && sourceDoc !== liveDoc) {
            resolvedAnchor = anchor(liveDoc)
        }
        return resolvedAnchor
    }

    async _awaitDirection() {
        if (this._vertical === null) await this._directionReady;
    }
    async _getSentinelVisibilities({ allowRetry = true } = {}) {
        await nextFrame()

        const perfStart = typeof performance !== 'undefined' && typeof performance.now === 'function'
            ? performance.now()
            : null

        const doc = this._view?.document
        if (!doc?.body) return []

        if (this._cachedSentinelDoc !== doc) {
            this._cachedSentinelDoc = doc
            this._cachedSentinelElements = Array.from(doc.body.getElementsByTagName('reader-sentinel'))
            this._cachedTrackingSections = Array.from(doc.querySelectorAll(MANABI_TRACKING_SECTION_SELECTOR))
            this._sentinelsInitialized = false
        } else if (!Array.isArray(this._cachedSentinelElements) || this._cachedSentinelElements.length === 0) {
            this._cachedSentinelElements = Array.from(doc.body.getElementsByTagName('reader-sentinel'))
        }

        const sentinelElements = this._cachedSentinelElements
        logEBookPageNumLimited('bake:sentinels:init', {
            sectionIndex: this._index ?? null,
            sentinelCount: sentinelElements.length,
            trackingSections: this._cachedTrackingSections?.length ?? null,
            allowRetry,
            containerClientWidth: this._container?.clientWidth ?? null,
            containerClientHeight: this._container?.clientHeight ?? null,
            containerScrollWidth: this._container?.scrollWidth ?? null,
            containerScrollHeight: this._container?.scrollHeight ?? null,
        })

        const applyVisibility = reason => {
            if (this._cachedTrackingSections.length === 0) return
            applySentinelVisibilityToTrackingSections(doc, {
                visibleSentinels: this._visibleSentinelElements,
                logReason: reason,
                container: this._container,
                sectionsCache: this._cachedTrackingSections,
            })
        }

        const bodyClasses = Array.from(doc.body?.classList ?? [])
        const isBakingHidden = bodyClasses.includes(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS) ||
            bodyClasses.includes(MANABI_TRACKING_PREBAKE_HIDDEN_CLASS)

        if (sentinelElements.length === 0) {
            if (isBakingHidden && allowRetry && this._trackingSizeBakeInFlight) {
                try { await this._trackingSizeBakeInFlight } catch {}
                // Retry once to avoid infinite loops
                return await this._getSentinelVisibilities({ allowRetry: false })
            }
            applyVisibility('sentinel-visibility:none')
            this._resetSentinelObservers()
            return []
        }

        // Clear any prior snapshot (in case a previous call bailed early).
        this._visibleSentinelElements.clear?.()

        const docChanged = this._sentinelGroupsDoc !== doc
        const needsSync = docChanged || !this._sentinelsInitialized

        if (needsSync) {
            const groupSize = await this._calculateSentinelGroupSize(sentinelElements.length)
            this._syncSentinelGroups(doc, sentinelElements, groupSize)
            this._sentinelsInitialized = true
        }

        const groupCount = this._sentinelGroups.length
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
            const group = this._sentinelGroups[groupIndex]
            if (!group) continue

            this._activateSentinelGroup(group)
            observedThisCall += group.elements.length
            this._flushSentinelRecords(groupIndex, groupIndex)

            minActive = Math.min(minActive, groupIndex)
            maxActive = Math.max(maxActive, groupIndex)

            snapshot = this._collectVisibleSentinelSnapshot()
            if (snapshot.visibleIds.length === 0) continue

            const minGroup = Math.floor(snapshot.minIndex / this._sentinelGroupSize)
            const maxGroup = Math.floor(snapshot.maxIndex / this._sentinelGroupSize)
            const minOnEdge = snapshot.minIndex === (this._sentinelGroups[minGroup]?.startIndex ?? snapshot.minIndex + 1)
            const maxOnEdge = snapshot.maxIndex === (this._sentinelGroups[maxGroup]?.endIndex ?? snapshot.maxIndex - 1)

            if (!minOnEdge && !maxOnEdge) break
        }

        // Ensure the observers reflect the final active window (ring span).
        this._updateSentinelGroupActivation(minActive, maxActive)
        this._flushSentinelRecords(minActive, maxActive)

        snapshot = this._collectVisibleSentinelSnapshot()

        // Fallback: if still nothing, observe everything.
        if (snapshot.visibleIds.length === 0 && this._sentinelGroups.length > 0) {
            this._updateSentinelGroupActivation(0, this._sentinelGroups.length - 1)
            observedThisCall = sentinelElements.length
            this._flushSentinelRecords(0, this._sentinelGroups.length - 1)
            snapshot = this._collectVisibleSentinelSnapshot()
        }

        const { visibleIds, minIndex, maxIndex } = snapshot

        applyVisibility('sentinel-visibility')

        const logStart = snapshot.visibleIds.length > 0 ? minActive : 0
        const logEnd = snapshot.visibleIds.length > 0 ? maxActive : Math.max(0, groupCount - 1)

        // Stop observing after snapshot to avoid persistent overhead; groups will be reactivated on next call.
        this._updateSentinelGroupActivation(null, null)
        this._visibleSentinelElements.clear?.()

        logEBookPageNumLimited('bake:sentinels:snapshot', {
            sectionIndex: this._index ?? null,
            visibleCount: visibleIds.length,
            minIndex,
            maxIndex,
            observedThisCall,
            totalGroups: this._sentinelGroups?.length ?? null,
        })
        return visibleIds
    }
    _disconnectElementVisibilityObserver() {
        if (this._elementVisibilityObserver) {
            this._elementVisibilityObserver.disconnect();
            this._elementVisibilityObserver = null;
        }
        if (this._elementMutationObserver) {
            this._elementMutationObserver.disconnect();
            this._elementMutationObserver = null;
        }
    }
    _isSingleMediaElementWithoutText() {
        const container = this._view.document.getElementById('reader-content');
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
    async _beforeRender({
        vertical,
        verticalRTL,
        rtl,
        //        background
    }) {
        this._vertical = vertical
        this._verticalRTL = verticalRTL
        this._rtl = typeof rtl === 'boolean' ? rtl : (this.bookDir === 'rtl')
        this._top.classList.toggle('vertical', vertical)
        this._directionReady = new Promise(r => (this._directionReadyResolve = r));

        // set background to `doc` background
        // this is needed because the iframe does not fill the whole element
        //        this._background.style.background = background

        this.style.display = 'block'

        const {
            width,
            height
        } = await this.sizes()
        const size = vertical ? height : width
        const {
            fullWidthCharacterAdvancePx,
            fullWidthCharacterThreshold,
            columnizationThresholdPx,
        } = resolveColumnizationThreshold({
            doc: this._view.document,
            vertical,
        })
        const shouldColumnizeForThreshold = size > columnizationThresholdPx

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
        //                const style = getComputedStyle(this._top)
        //                const maxInlineSize = parseFloat(style.getPropertyValue('--_max-inline-size'))
        //                const maxColumnCount = parseInt(style.getPropertyValue('--_max-column-count-spread'))
        //                const topMargin = parseFloat(style.getPropertyValue('--_top-margin'))
        //                const bottomMargin = parseFloat(style.getPropertyValue('--_bottom-margin'))
        //                console.log("max in", maxInlineSize, maxInlineSize)
        //                console.log("max col cnt", maxColumnCount, maxColumnCountSpread)
        //                console.log("top marg", topMargin, topMargin)
        //                console.log("bot marg", bottomMargin, bottomMargin)

        this._topMargin = topMargin
        this._bottomMargin = bottomMargin
        this._view.document.documentElement.style.setProperty('--_max-inline-size', maxInlineSize)

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
        this._column = flow !== 'scrolled'
        if (this._sameDocumentMode) {
            this._view?.element?.style?.setProperty?.('direction', 'ltr')
            this._view?.document?.documentElement?.style?.setProperty?.('direction', 'ltr')
            this._view?.document?.body?.style?.setProperty?.('direction', 'ltr')
            this._sameDocumentViewport?.style?.setProperty?.('direction', 'ltr')
            this._container?.style?.setProperty?.('direction', 'ltr')
        }

        if (flow === 'scrolled') {
            // FIXME: vertical-rl only, not -lr
            //this.setAttribute('dir', vertical ? 'rtl' : 'ltr')
            this._top.style.padding = '0'
            const columnWidth = shouldColumnizeForThreshold
                ? columnizationThresholdPx
                : size

            this.heads = null
            this.feet = null
            this._header.replaceChildren()
            this._footer.replaceChildren()

            return {
                flow,
                topMargin,
                bottomMargin,
                gap,
                columnWidth,
                shouldColumnizeForThreshold,
                fullWidthCharacterAdvancePx,
                fullWidthCharacterThreshold,
                columnizationThresholdPx,
                usePaginate: false,
                writingMode,
                direction: resolvedDir,
            }
        }

        let divisor, columnWidth
        const isSingleMediaElementWithoutText = this._isSingleMediaElementWithoutText()
        if (isSingleMediaElementWithoutText) {
            columnWidth = maxInlineSize
            this._view.document.body?.classList.add('reader-is-single-media-element-without-text')
        } else {
            this._view.document.body?.classList.remove('reader-is-single-media-element-without-text')
            if (!shouldColumnizeForThreshold) {
                divisor = 1
                columnWidth = size - gap
            } else {
                const effectiveInlineSize = columnizationThresholdPx
                divisor = Math.min(maxColumnCount, Math.ceil(size / effectiveInlineSize))
                columnWidth = (size / divisor) - gap
            }
        }

        this.setAttribute('dir', rtl ? 'rtl' : 'ltr')

        const marginalDivisor = shouldColumnizeForThreshold
            ? (vertical
                ? Math.min(2, Math.ceil(width / maxInlineSize))
                : divisor)
            : 1
        const marginalStyle = {
            gridTemplateColumns: `repeat(${marginalDivisor}, 1fr)`,
            gap: `${gap}px`,
            direction: this.bookDir === 'rtl' ? 'rtl' : 'ltr',
        }
        Object.assign(this._header.style, marginalStyle)
        Object.assign(this._footer.style, marginalStyle)
        const heads = makeMarginals(marginalDivisor, 'head')
        const feet = makeMarginals(marginalDivisor, 'foot')
        this.heads = heads.map(el => el.children[0])
        this.feet = feet.map(el => el.children[0])
        this._header.replaceChildren(...heads)
        this._footer.replaceChildren(...feet)

        return {
            height,
            width,
            topMargin,
            bottomMargin,
            gap,
            columnWidth,
            divisor,
            shouldColumnizeForThreshold,
            fullWidthCharacterAdvancePx,
            fullWidthCharacterThreshold,
            columnizationThresholdPx,
            usePaginate: false,
            writingMode,
            direction: resolvedDir,
        }
    }
    async render() {
        if (!this._view) {
            return
        }

        // avoid unwanted triggers
        //        this._hasResizeObserverTriggered = false
        //        this._resizeObserver.observe(this._container);

        await this._view.render(await this._beforeRender({
            vertical: this._vertical,
            rtl: this._rtl,
        }))
        //            await this._scrollToAnchor(this._anchor) // already called via render -> ... -> expand -> onExpand
    }

    get scrolled() {
        return this.getAttribute('flow') === 'scrolled'
    }
    async scrollProp() {
        await this._awaitDirection();
        const {
            scrolled
        } = this
        return this._vertical ? (scrolled ? 'scrollLeft' : 'scrollTop') :
            scrolled ? 'scrollTop' : 'scrollLeft'
    }
    async sideProp() {
        await this._awaitDirection();
        const {
            scrolled
        } = this
        return this._vertical ? (scrolled ? 'width' : 'height') :
            scrolled ? 'height' : 'width'
    }
    async sizes() {
        // Avoid cached measurements; the iframe can be hidden during load which would
        // record zeros and break pagination. Always read current client sizes.
        const sizes = {
            width: this._container.clientWidth,
            height: this._container.clientHeight,
        }
        this._logSizesOnce({
            event: 'sizes',
            sectionIndex: this._index ?? null,
            width: sizes.width,
            height: sizes.height,
            scrollWidth: this._container.scrollWidth,
            scrollHeight: this._container.scrollHeight,
            scrolled: this.scrolled,
            vertical: this._vertical,
            rtl: this._rtl,
            rect: this._container.getBoundingClientRect ? {
                width: Math.round(this._container.getBoundingClientRect().width),
                height: Math.round(this._container.getBoundingClientRect().height),
                top: Math.round(this._container.getBoundingClientRect().top),
                left: Math.round(this._container.getBoundingClientRect().left),
            } : null,
            styleHeight: this._container?.style?.height ?? null,
            overflow: typeof getComputedStyle === 'function'
                ? getComputedStyle(this._container).overflow
                : null,
            bakeReady: this._trackingSizeBakeReady,
            pendingBakeReason: this._pendingTrackingSizeBakeReason ?? null,
            bakeInFlight: !!this._trackingSizeBakeInFlight,
            usingCache: false,
        })
        return sizes
    }
    async size() {
        const s = (await this.sizes())[await this.sideProp()]
        logEBookPageNumLimited('size', {
            sectionIndex: this._index ?? null,
            size: s,
            scrolled: this.scrolled,
            vertical: this._vertical,
            rtl: this._rtl,
        })
        // Detect collapses or missing layout that can cascade into bogus page counts.
        const container = this._container
        const containerClientW = container?.clientWidth ?? null
        const containerClientH = container?.clientHeight ?? null
        if (!Number.isFinite(s) || s === 0 || containerClientW === 0 || containerClientH === 0) {
            const rect = container?.getBoundingClientRect?.()
            logEBookPageNumLimited('size:anomaly', {
                sectionIndex: this._index ?? null,
                size: s,
                clientWidth: containerClientW,
                clientHeight: containerClientH,
                scrollWidth: container?.scrollWidth ?? null,
                scrollHeight: container?.scrollHeight ?? null,
                scrolled: this.scrolled,
                vertical: this._vertical,
                rtl: this._rtl,
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
        if (this._isCacheWarmer) return 0
        if (this._usesSameDocumentPagePositioningSync()) {
            const [pageCount, size] = await Promise.all([
                this._getSameDocumentResolvedPageCount(),
                this.size(),
            ])
            const val = pageCount * size
            this._logViewSizeOnce({
                event: 'viewSize:same-document',
                sectionIndex: this._index ?? null,
                side: await this.sideProp(),
                clientWidth: this._container?.clientWidth ?? null,
                clientHeight: this._container?.clientHeight ?? null,
                scrollWidth: this._container?.scrollWidth ?? null,
                scrollHeight: this._container?.scrollHeight ?? null,
                returned: val,
                scrolled: this.scrolled,
                vertical: this._vertical,
                rtl: this._rtl,
                bakeReady: this._trackingSizeBakeReady,
                pendingBakeReason: this._pendingTrackingSizeBakeReason ?? null,
                bakeInFlight: !!this._trackingSizeBakeInFlight,
                usingCache: false,
            })
            return val
        }
        const view = this._view
        if (!view || !view.element) return 0
        const element = view.element
        const side = await this.sideProp()
        const scrollWidth = element.scrollWidth
        const scrollHeight = element.scrollHeight
        const val = (!this.scrolled)
            ? (side === 'width' ? scrollWidth : scrollHeight)
            : (side === 'width' ? element.clientWidth : element.clientHeight)

        this._logViewSizeOnce({
            event: 'viewSize',
            sectionIndex: this._index ?? null,
            side,
            clientWidth: element.clientWidth,
            clientHeight: element.clientHeight,
            scrollWidth,
            scrollHeight,
            returned: val,
            scrolled: this.scrolled,
            vertical: this._vertical,
            rtl: this._rtl,
            elemRect: element.getBoundingClientRect ? {
                width: Math.round(element.getBoundingClientRect().width),
                height: Math.round(element.getBoundingClientRect().height),
                top: Math.round(element.getBoundingClientRect().top),
                left: Math.round(element.getBoundingClientRect().left),
            } : null,
            parentRect: this._container?.getBoundingClientRect ? {
                width: Math.round(this._container.getBoundingClientRect().width),
                height: Math.round(this._container.getBoundingClientRect().height),
                top: Math.round(this._container.getBoundingClientRect().top),
                left: Math.round(this._container.getBoundingClientRect().left),
            } : null,
            elemStyleHeight: element?.style?.height ?? null,
            elemStyleDisplay: element?.style?.display ?? null,
            parentStyleHeight: this._container?.style?.height ?? null,
            parentOverflow: typeof getComputedStyle === 'function'
                ? getComputedStyle(this._container).overflow
                : null,
            bakeReady: this._trackingSizeBakeReady,
            pendingBakeReason: this._pendingTrackingSizeBakeReason ?? null,
            bakeInFlight: !!this._trackingSizeBakeInFlight,
            usingCache: false,
        })

        return val
    }
    _logSizesOnce(payload) {
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
        if (this._lastSizesSnapshot === key) return
        this._lastSizesSnapshot = key
        logEBookPageNumLimited(payload.event, payload)
    }

    _logViewSizeOnce(payload) {
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
        if (this._lastViewSizeSnapshot === key) return
        this._lastViewSizeSnapshot = key
        logEBookPageNumLimited(payload.event, payload)
    }
    async start() {
        if (this._usesSameDocumentPagePositioningSync()) {
            const pageIndex = await this._getSameDocumentClampedPageIndex()
            const size = await this.size()
            const start = pageIndex * size
            logEBookPageNumLimited('start:same-document', {
                sectionIndex: this._index ?? null,
                start,
                size,
                pageIndex,
            })
            return start
        }
        const scrollProp = await this.scrollProp()
        const raw = this._container[scrollProp]
        const start = Math.abs(raw)
        logEBookPageNumLimited('start', {
            sectionIndex: this._index ?? null,
            scrollProp,
            rawScrollValue: raw,
            start,
            scrolled: this.scrolled,
            vertical: this._vertical,
            rtl: this._rtl,
        })
        return start
    }
    async end() {
        //        await this._awaitDirection();
        return (await this.start()) + (await this.size())
    }
    async page() {
        if (this._usesSameDocumentPagePositioningSync()) {
            const page = this._getSameDocumentResolvedNavigationStateSync().pageIndex
            logEBookPageNumLimited('page:same-document', {
                sectionIndex: this._index ?? null,
                page,
            })
            return page
        }
        const start = await this.start()
        const end = await this.end()
        const size = await this.size()
        const raw = (start + end) / 2
        const page = Math.floor(raw / size)
        logEBookPageNumLimited('page', {
            sectionIndex: this._index ?? null,
            start,
            end,
            rawMidpoint: raw,
            size,
            page,
            scrolled: this.scrolled,
            vertical: this._vertical,
            rtl: this._rtl,
        })
        return page
    }
    async pages() {
        if (this._usesSameDocumentPagePositioningSync()) {
            const livePageCount = this._getSameDocumentResolvedNavigationStateSync().pageCount
            logEBookPageNumLimited('pages:same-document', {
                sectionIndex: this._index ?? null,
                pages: livePageCount,
                scrolled: this.scrolled,
                vertical: this._vertical,
                rtl: this._rtl,
            })
            return livePageCount
        }
        const livePageCount = this._getLiveChunkPageCount()
        if (livePageCount != null && !this.scrolled) {
            logEBookPageNumLimited('pages:live-chunk', {
                sectionIndex: this._index ?? null,
                pages: livePageCount,
                scrolled: this.scrolled,
                vertical: this._vertical,
                rtl: this._rtl,
            })
            return livePageCount
        }
        const viewSize = await this.viewSize()
        const size = await this.size()
        const pages = Math.round(viewSize / size)
        const sentinelAdjusted = MANABI_RENDERER_SENTINEL_ADJUST_ENABLED
            && this._hasSentinels
            && !this.scrolled
            && !this._vertical
            && pages > 2;
        const textPages = sentinelAdjusted ? Math.max(1, pages - 2) : pages
        logEBookPageNumLimited('pages', {
            sectionIndex: this._index ?? null,
            viewSize,
            size,
            pages,
            textPages,
            sentinelAdjusted,
            scrolled: this.scrolled,
            vertical: this._vertical,
            rtl: this._rtl,
        })
        // If we ever report a single page while text pages likely exceed 1, log extra context.
        if (pages === 1 && this._index !== null) {
            logEBookPageNumLimited('pages:single-page', {
                sectionIndex: this._index,
                viewSize,
                size,
                scrolled: this.scrolled,
                vertical: this._vertical,
                rtl: this._rtl,
                containerClientWidth: this._container?.clientWidth ?? null,
                containerClientHeight: this._container?.clientHeight ?? null,
                containerScrollHeight: this._container?.scrollHeight ?? null,
                containerScrollWidth: this._container?.scrollWidth ?? null,
                viewCachedWidth: this._view?.cachedViewSize?.width ?? null,
                viewCachedHeight: this._view?.cachedViewSize?.height ?? null,
                cachedSizes: this._cachedSizes ? { ...this._cachedSizes } : null,
                viewClientHeight: this._view?.element?.clientHeight ?? null,
                viewScrollHeight: this._view?.element?.scrollHeight ?? null,
                scrollHeightEqualsClientHeight: this._view?.element ? this._view.element.scrollHeight === this._view.element.clientHeight : null,
            })
        }
        return pages
    }
    async scrollBy(dx, dy) {
        await new Promise(resolve => {
            requestAnimationFrame(async () => {
                const delta = this._vertical ? dy : dx
                const element = this._container
                const scrollProp = await this.scrollProp()
                const [offset, a, b] = this._scrollBounds
                const rtl = this._rtl
                const min = rtl ? offset - b : offset - a
                const max = rtl ? offset + a : offset + b
                element[scrollProp] = Math.max(min, Math.min(max,
                    element[scrollProp] + delta))
                this._cachedStart = null; // TODO: Needed here?
                resolve()
            })
        })
    }
    async snap(vx, vy) {
        const velocity = this._vertical ? vy : vx
        const [offset, a, b] = this._scrollBounds
        const start = await this.start()
        const end = await this.end()
        const pages = await this.pages()
        const size = await this.size()
        const min = Math.abs(offset) - a
        const max = Math.abs(offset) + b
        const d = velocity * (this._rtl ? -size : size)
        const page = Math.floor(
            Math.max(min, Math.min(max, (start + end) / 2 +
                (isNaN(d) ? 0 : d))) / size)

        await this._scrollToPage(page, 'snap').then(async () => {
            const dir = page <= 0 ? -1 : page >= pages - 1 ? 1 : null
            if (dir) return await this._goTo({
                index: this._adjacentIndex(dir),
                anchor: dir < 0 ? () => 1 : () => 0,
                reason: 'page',
            })
        })
    }
    _onTouchStart(e) {
        const touch = e.changedTouches[0];
        // Determine if touch began in host container or inside the iframe’s document
        const target = touch.target;
        const inHost = this._container.contains(target);
        const inIframe = this._view?.document && target.ownerDocument === this._view.document;
        if (!inHost && !inIframe) {
            this._touchState = null;
            return;
        }
        this._clearPendingChevronReset();
        this._touchHasShownChevron = false;
        this._touchTriggeredNav = false;
        this._maxChevronLeft = 0;
        this._maxChevronRight = 0;
        this._touchState = {
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
            const sel = this._view?.document?.getSelection?.();
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
                    this._isAdjustingSelectionHandle = true;
                    return;
                }
            }
        }
        this._isAdjustingSelectionHandle = false;
    }
    async _onTouchMove(e) {
        // If touchStart was ignored or missing, do nothing
        if (!this._touchState) return;
        if (this._isAdjustingSelectionHandle) return;
        e.preventDefault();
        const touch = e.changedTouches[0];
        const state = this._touchState;
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

            this._lastSwipeNavAt = Date.now();
            this._lastSwipeNavDirection = navDetail.direction;
            this._touchTriggeredNav = true;
            this._emitChevronOpacity({
                leftOpacity: navDetail.leftOpacity,
                rightOpacity: navDetail.rightOpacity,
                holdMs: this._chevronTriggerHoldMs,
                fadeMs: this._chevronFadeMs,
            }, 'swipe:navImmediate');
            this._logChevronDispatch('swipeNav:trigger', {
                dx,
                dy,
                direction: navDetail.direction,
                bookDir: this.bookDir ?? null,
                rtl: this._rtl,
            });
            await navDetail.navigate();
            this._scheduleChevronHide(this._chevronTriggerHoldMs + 80);
            // After navigation triggered via swipe, proactively reset any stale chevron state.
            this._logResetNeed('postSwipeNav');
            this._emitChevronReset('reset:postSwipeNav');
        } else {
            if (CHEVRON_SWIPE_PREVIEW_ENABLED) {
                this._updateSwipeChevron(dx, minSwipe, 'swipe');
            }
        }
    }
    _onTouchEnd(e) {
        const hadNav = this._touchTriggeredNav;
        const hadChevron = this._touchHasShownChevron;

        this._touchState = null;

        // If we just loaded a new section, skip the opacity reset for non-nav touches
        if (this._skipTouchEndOpacity && !hadNav) {
            this._logChevronDispatch('sideNavChevronOpacity:touchEnd:skipReset', { reason: 'skipTouchEndOpacity' });
            this._skipTouchEndOpacity = false
            this._touchHasShownChevron = false;
            this._touchTriggeredNav = false;
            this._maxChevronLeft = 0;
            this._maxChevronRight = 0;
            return
        }

        // Always clear any outstanding reset timers once the finger lifts
        this._clearPendingChevronReset();

        if (hadNav) {
            // Navigation already occurred; force a full chevron reset so UI controls re-enable
            this._logResetNeed('touchEnd:nav');
            this._emitChevronReset('reset:touchEndNav');
        } else if (hadChevron) {
            // If swipe never triggered navigation but showed the chevron, fade it out now.
            this._logResetNeed('touchEnd:noNav');
            this._scheduleChevronHide(0);
        }

        this._touchHasShownChevron = false;
        this._touchTriggeredNav = false;
        this._maxChevronLeft = 0;
        this._maxChevronRight = 0;
        this._skipTouchEndOpacity = false;
    }

    _forceEndTouchGesture(source = 'unknown') {
        // Safety net: clear lingering swipe state after navigation/display completes.
        this._logResetNeed('forceEndTouchGesture', { source });
        this._clearPendingChevronReset();
        this._touchState = null;
        this._touchHasShownChevron = false;
        this._touchTriggeredNav = false;
        this._maxChevronLeft = 0;
        this._maxChevronRight = 0;
        this._skipTouchEndOpacity = false;
        this._emitChevronReset('reset:forceEndTouchGesture');
    }

    _onTouchCancel(e) {
        // Treat cancellation as an end-of-gesture and force-reset chevrons/state.
        const hadGesture = this._touchHasShownChevron || this._touchTriggeredNav;
        this._touchState = null;
        this._clearPendingChevronReset();
        if (hadGesture) {
            this._logResetNeed('touchCancel');
            this._emitChevronReset('reset:touchCancel');
        }
        this._touchHasShownChevron = false;
        this._touchTriggeredNav = false;
        this._maxChevronLeft = 0;
        this._maxChevronRight = 0;
        this._skipTouchEndOpacity = false;
    }
    // allows one to process rects as if they were LTR and horizontal
    async _getRectMapper() {
        await this._awaitDirection();
        if (this.scrolled) {
            const size = await this.viewSize()
            const topMargin = this._topMargin
            const bottomMargin = this._bottomMargin
            return this._vertical ?
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
        return this._rtl ?
            ({
                left,
                right
            }) =>
            ({
                left: pxSize - right,
                right: pxSize - left
            }) :
            this._vertical ?
                ({
                    top,
                    bottom
                }) => ({
                    left: top,
                    right: bottom
                }) :
                f => f
    }
    _wheelCooldown = false;
    _lastWheelDeltaX = 0;
    _lastSwipeNavAt = null;
    _lastSwipeNavDirection = null; // 'forward' | 'backward'
    _touchHasShownChevron = false;
    _touchTriggeredNav = false;
    _maxChevronLeft = 0;
    _maxChevronRight = 0;
    _lastChevronEmit = { left: null, right: null };
    _chevronTriggerHoldMs = 420;
    _chevronFadeMs = 180;
    _pendingChevronResetTimer = null;
    _resetLoopGuard = false;
    _logResetNeed(reason, extra = {}) {
        try {
            const line = `# EBOOK CHEVRESET NEED ${JSON.stringify({ reason, ...extra })}`;
            window.webkit?.messageHandlers?.print?.postMessage?.(line);
            console.log(line);
        } catch (_err) {}
    }
    _handleChevronResetEvent = () => {
        if (this._resetLoopGuard) return;
        this._logResetNeed('external-resetSideNavChevrons');
        this._emitChevronReset('reset:event');
    };
    _emitChevronReset(source = 'reset:auto') {
        // Stop any in-flight auto-hide timers before fanning out a reset.
        this._clearPendingChevronReset();
        try {
            const line = `# EBOOK CHEVRESET ${JSON.stringify({ source })}`;
            window.webkit?.messageHandlers?.print?.postMessage?.(line);
            console.log(line);
        } catch (_err) {}
        this._lastChevronEmit = { left: null, right: null };
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
        this._resetLoopGuard = true;
        try {
            document.dispatchEvent(new CustomEvent('resetSideNavChevrons', { detail: { source } }));
        } finally {
            setTimeout(() => { this._resetLoopGuard = false; }, 0);
        }
    }
    _clearPendingChevronReset() {
        if (!this._pendingChevronResetTimer) return;
        clearTimeout(this._pendingChevronResetTimer);
        this._pendingChevronResetTimer = null;
    }
    _scheduleChevronHide(delayMs = this._chevronTriggerHoldMs) {
        this._clearPendingChevronReset();
        this._logResetNeed('scheduleHide', { delayMs });
        this._pendingChevronResetTimer = setTimeout(() => {
            this._pendingChevronResetTimer = null;
            this._emitChevronOpacity({
                leftOpacity: '',
                rightOpacity: '',
                fadeMs: this._chevronFadeMs,
            }, 'chevron:autoHide');
            this._emitChevronReset('reset:autoHide');
        }, delayMs);
    }
    async _onWheel(e) {
        if (this.scrolled) return;
        e.preventDefault();
        if (Math.abs(e.deltaX) < Math.abs(e.deltaY)) return;

        const TRIGGER_THRESHOLD = 12;
        const RESET_THRESHOLD = 3;
        const REVEAL_CHEVRON_THRESHOLD = 5;

        // Early exit for "momentum falling" (hide chevrons if armed, deltaX dropping, and below threshold)
        if (
            this._wheelArmed &&
            Math.abs(e.deltaX) < Math.abs(this._lastWheelDeltaX) &&
            Math.abs(e.deltaX) < TRIGGER_THRESHOLD
        ) {
            this._emitChevronOpacity({
                leftOpacity: '',
                rightOpacity: ''
            }, 'wheel:momentumFalling');
            this._lastWheelDeltaX = e.deltaX;
            return;
        }

        if (this._wheelArmed) {
            if (Math.abs(e.deltaX) > REVEAL_CHEVRON_THRESHOLD) {
                this._updateSwipeChevron(-e.deltaX, TRIGGER_THRESHOLD, 'wheel:reveal');
            } else {
                this._updateSwipeChevron(0, TRIGGER_THRESHOLD, 'wheel:resetReveal');
            }
        }

        if (this._wheelArmed && Math.abs(e.deltaX) > TRIGGER_THRESHOLD) {
            this._wheelArmed = false;
            this._wheelCooldown = true;
            if (e.deltaX > 0) {
                await this.prev();
            } else {
                await this.next();
            }
            this._updateSwipeChevron(-e.deltaX, TRIGGER_THRESHOLD, 'wheel:triggered')
            setTimeout(() => {
                this._wheelCooldown = false;
            }, 100);
        } else if (!this._wheelArmed && !this._wheelCooldown && Math.abs(e.deltaX) < RESET_THRESHOLD) {
            this._wheelArmed = true;
        }
        this._lastWheelDeltaX = e.deltaX;
    }
    async _scrollToRect(rect, reason) {
        if (this.scrolled) {
            const rectMapper = await this._getRectMapper();
            const offset = rectMapper(rect).left - this._topMargin
            return await this._scrollTo(offset, reason)
        }
        const rectMapper = await this._getRectMapper();
        const offset = rectMapper(rect).left
        return await this._scrollToPage(Math.floor(offset / (await this.size())) + (this._rtl ? -1 : 1), reason)
    }
    async _scrollTo(offset, reason, smooth) {
        await this._awaitDirection();
        const scroll = async () => {
            this._cachedStart = null;
            const element = this._container
            const scrollProp = await this.scrollProp()
            const size = await this.size()
            const atStart = await this.atStart()
            const atEnd = await this.atEnd()
            if (element[scrollProp] === offset) {
                this._scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size]
                await this._afterScroll(reason)
                return
            }
            // FIXME: vertical-rl only, not -lr
            if (this.scrolled && this._vertical) offset = -offset
            if ((reason === 'snap' || smooth) && this.hasAttribute('animated')) return animate(
                element[scrollProp], offset, 300, easeOutQuad,
                x => element[scrollProp] = x,
            ).then(async () => {
                this._scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size]
                await this._afterScroll(reason)
            })
            else {
                element[scrollProp] = offset
                this._scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size]
                await this._afterScroll(reason)
            }
        }

        //            // Prevent new transitions while one is running
        //            if (this._transitioning) {
        //                await scroll();
        //                return;
        //            }

        //            if (
        //                !this._view ||
        //                document.visibilityState !== 'visible' ||
        //                (reason === 'snap' || reason === 'anchor' || reason === 'selection') ||
        //                typeof document.startViewTransition !== 'function'
        //                ) {
        return new Promise(resolve => {
            requestAnimationFrame(async () => {
                if (reason === 'snap' || reason === 'anchor' || reason === 'selection' || reason === 'navigation') {
                    await scroll()
                } else {
                    this._container.classList.add('view-fade')
                    // Allow the browser to paint the fade
                    /*await new Promise(r => setTimeout(r, 65));
                     this._container.classList.add('view-faded')*/
                    await scroll()
                    this._container.classList.remove('view-faded')
                    this._container.classList.remove('view-fade')
                }
                resolve()
            })
        })
    }
    async _scrollToPage(page, reason, smooth) {
        const activeLayout = this._getActiveEbookSectionLayout()
        if (activeLayout?.hasPendingWarmup?.()) {
            activeLayout.ensurePageBuilt?.(page, {
                reason: reason ?? 'scrollToPage',
            })
        }
        if (this._usesSameDocumentPagePositioningSync()) {
            const { pageIndex, pageCount } = await this._getSameDocumentPreparedNavigationState(
                page,
                reason ?? 'scrollToPage'
            )
            setSameDocumentHostTurnDiagnostics({
                phase: 'scroll-to-page-begin',
                reason: reason ?? 'scrollToPage',
                currentPageIndex: pageIndex,
                pageCount,
                targetPageIndex: page,
            })
            await this._applySameDocumentPagePosition(page, {
                reason: reason ?? 'scrollToPage',
                smooth: !!smooth,
                resolvedPageCountOverride: pageCount,
            })
            await this._afterScroll(reason ?? 'scrollToPage')
            setSameDocumentHostTurnDiagnostics({
                phase: 'scroll-to-page-complete',
                reason: reason ?? 'scrollToPage',
                currentPageIndex: await this.page().catch(() => null),
                pageCount: await this.pages().catch(() => null),
                targetPageIndex: page,
            })
            return
        }
        this._view?.reconcileSameDocumentExpandedWidth?.()
        const size = await this.size()
        const shouldUsePositiveRTLPageOffset = this._sameDocumentMode
            && !this.scrolled
            && !this._vertical
            && this._rtl
        const offset = size * (shouldUsePositiveRTLPageOffset ? page : (this._rtl ? -page : page))
        const alternateRTLOffset = this._rtl ? size * -page : offset
        const scrollProp = await this.scrollProp()
        const beforePage = await this.page().catch(() => null)
        const beforeScrollValue = this._container?.[scrollProp] ?? null
        logEBookPageNumLimited('scrollToPage', {
            targetPage: page,
            reason,
            smooth: !!smooth,
            sectionIndex: this._index ?? null,
            size,
            offset,
            positiveRTLPageOffset: shouldUsePositiveRTLPageOffset,
            rtl: this._rtl,
            vertical: this._vertical,
        })
        await this._scrollTo(offset, reason, smooth)
        if (
            this._sameDocumentMode
            && !this.scrolled
            && !this._vertical
            && this._rtl
            && alternateRTLOffset !== offset
        ) {
            this._cachedStart = null
            const afterPrimaryPage = await this.page().catch(() => null)
            const afterPrimaryScrollValue = this._container?.[scrollProp] ?? null
            const targetDidAdvance = Number.isFinite(afterPrimaryPage) && Number.isFinite(beforePage)
                ? afterPrimaryPage > beforePage
                : Number.isFinite(afterPrimaryPage) && afterPrimaryPage > 0
            const shouldRetryWithAlternateOffset = !targetDidAdvance
                && afterPrimaryPage !== page
                && afterPrimaryScrollValue === beforeScrollValue
            if (shouldRetryWithAlternateOffset) {
                logEBookPageNumLimited('scrollToPage:rtl-retry', {
                    targetPage: page,
                    reason,
                    smooth: !!smooth,
                    sectionIndex: this._index ?? null,
                    size,
                    primaryOffset: offset,
                    alternateOffset: alternateRTLOffset,
                    beforePage,
                    afterPrimaryPage,
                    beforeScrollValue,
                    afterPrimaryScrollValue,
                })
                await this._scrollTo(alternateRTLOffset, reason, smooth)
            }
        }
    }
    async scrollToAnchor(anchor, select, reasonOverride) {
        //            await new Promise(resolve => requestAnimationFrame(resolve));
        const reason = reasonOverride || (select ? 'selection' : 'navigation');
        await this._scrollToAnchor(anchor, reason)
    }
    // TODO: Fix newer way and stop using this one that calculates getClientRects
    async _scrollToAnchor(anchor, reason = 'anchor') {
        //        console.log('#scrollToAnchor0...', anchor)
        this._anchor = anchor
        try {
        } catch (_error) {
            // diagnostics best-effort
        }
        logEBookPageNumLimited('scrollToAnchor:start', {
            reason,
            sectionIndex: this._index ?? null,
            anchorType: anchor?.nodeType ?? (typeof anchor),
            containerHeight: this._container?.clientHeight ?? null,
            containerWidth: this._container?.clientWidth ?? null,
        })
        const activeLayout = this._getActiveEbookSectionLayout()
        const sourceDoc = activeLayout?.getSourceDocument()
        const anchorDoc = anchor?.startContainer?.getRootNode?.() ?? anchor?.ownerDocument ?? null
        if (activeLayout && sourceDoc && anchorDoc === sourceDoc) {
            const pageIndex = activeLayout.pageIndexForAnchor(anchor)
            if (pageIndex != null) {
                await this._scrollToPage(pageIndex, reason)
                return
            }
        }
        const rects = uncollapse(anchor)?.getClientRects?.()
        // if anchor is an element or a range
        if (rects) {
            // when the start of the range is immediately after a hyphen in the
            // previous column, there is an extra zero width rect in that column
            const rect = Array.from(rects)
                .find(r => r.width > 0 && r.height > 0) || rects[0]
            if (!rect) return
            await this._scrollToRect(rect, reason)
            return
        }
        // if anchor is a fraction
        if (this.scrolled) {
            const viewSize = await this.viewSize()
            await this._scrollTo(anchor * (await this.viewSize()), reason)
            return
        }
        const pageCount = await this.pages()
        if (!pageCount) return
        const livePageCount = this._getLiveChunkPageCount()
        const textPages = livePageCount != null
            ? livePageCount
            : pageCount - 2
        const newPage = Math.max(0, Math.round(anchor * Math.max(0, textPages - 1)))
        logEBookPageNumLimited('scrollToAnchor:fraction', {
            reason,
            sectionIndex: this._index ?? null,
            anchorFraction: anchor,
            textPages,
            targetPage: livePageCount != null ? newPage : newPage + 1,
            viewSize: await this.viewSize(),
        })
        await this._scrollToPage(livePageCount != null ? newPage : newPage + 1, reason)
    }
    async _NscrollToAnchor(anchor, reason = 'anchor') {
        //        console.log("#scrollToAnchor...cached sizes:", this._cachedSizes, "real sizes: ", await this.sizes())
        await this._awaitDirection();

        return new Promise(resolve => {
            requestAnimationFrame(async () => {
                //                console.log("#scrollToAnchor...frames...cached sizes:", this._cachedSizes, "real sizes: ", await this.sizes())
                this._anchor = anchor;
                //                console.log('scrollToAnchor: anchor=', anchor);
                // Determine anchor target (could be Range or Element)
                const anchorNode = uncollapse(anchor);

                // OG slow path: use getClientRects for sanity check
                //                const rects = anchorNode?.getClientRects?.();
                ////                console.log('OG clientRects:', rects);
                //                if (rects && rects.length > 0) {
                //                    const ogRect = Array.from(rects).find(r => r.width > 0 && r.height > 0) || rects[0];
                ////                    console.log('OG rect chosen:', ogRect);
                //                    //                        await this._scrollToRect(ogRect, reason);
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
                        while (current && current !== this._container) {
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
                            if (current !== this._container) {
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
                        const rectMapper = await this._getRectMapper();
                        const mapped = rectMapper(syntheticRect);
                        //                        console.log('mappedRect=', mapped);
                        // Use the same helper that the slow path relies on so we keep
                        // consistent behaviour between modes.
                        await this._scrollToRect(syntheticRect, reason);
                        resolve();
                        return;
                    }
                }
                // Fraction fallback
                if (this.scrolled) {
                    await this._scrollTo(anchor * (await this.viewSize()), reason);
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
                await this._scrollToPage(newPage + 1, reason);
                resolve();
            });
        });
    }
    async _getVisibleRange() {
        //            console.log("getVisibleRange...")
        await this._awaitDirection();
        const activeLayout = this._getActiveEbookSectionLayout()
        if (activeLayout) {
            const range = activeLayout.visibleSourceRange(await this.page())
            if (range) {
                return range
            }
        }
        //            console.log("getVisibleRange... await refreshElementVisibilityObserver..")
        const visibleSentinelIDs = await this._getSentinelVisibilities()
        //            await new Promise(r => requestAnimationFrame(r));

        //            console.log("getVisibleRange... awaited refreshElementVisibilityObserver")
        //            console.log("getVisibleRange... sentinels", this._visibleSentinelIDs.size)

        // Find the first and last visible content node, skipping <reader-sentinel> and manabi-* elements

        const doc = this._view.document

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
    async _dispatchSyntheticRelocate(reason = 'display', originalError = null) {
        try {
            const index = this._index
            const detail = {
                reason,
                index,
                sectionIndex: index,
            }

            let currentPage = null
            let pageCount = null
            try {
                [currentPage, pageCount] = await Promise.all([
                    this.page(),
                    this.pages(),
                ])
            } catch (_) {}

            const normalizedPageCount = Number.isFinite(pageCount) && pageCount > 0 ? pageCount : null
            const normalizedPageNumber = Number.isFinite(currentPage) && currentPage >= 0
                ? currentPage + 1
                : null
            if (normalizedPageNumber != null) detail.pageNumber = normalizedPageNumber
            if (normalizedPageCount != null) detail.pageCount = normalizedPageCount
            if (normalizedPageCount != null) {
                detail.size = 1 / normalizedPageCount
                detail.fraction = normalizedPageNumber != null
                    ? Math.max(0, Math.min(1, (normalizedPageNumber - 1) / normalizedPageCount))
                    : 0
            }

            try {
                const activeLayout = this._getActiveEbookSectionLayout()
                const range = activeLayout?.visibleSourceRange?.(currentPage ?? 0) ?? null
                if (range) detail.range = range
            } catch (_) {}

            logEBookPageNumLimited('relocate:detail', {
                reason,
                sectionIndex: index,
                scrolled: this.scrolled,
                fraction: detail.fraction ?? null,
                sizeFraction: detail.size ?? null,
                pageNumber: detail.pageNumber ?? null,
                pageCount: detail.pageCount ?? null,
                synthetic: true,
                originalError: originalError ? String(originalError) : null,
            })

            this._relocateGeneration += 1
            this.dispatchEvent(new CustomEvent('relocate', {
                detail
            }))
            return true
        } catch (_error) {
            return false
        }
    }
    async _afterScroll(reason) {
        if (this._isCacheWarmer) {
            return;
        }
        //            console.log("#afterScroll...")

        this._cachedStart = null;

        const activeLayout = this._getActiveEbookSectionLayout()
        const sameDocumentNavigationState = this._usesSameDocumentPagePositioningSync()
            ? this._getSameDocumentResolvedNavigationStateSync()
            : null
        let range = await this._getVisibleRange()
        if (
            sameDocumentNavigationState
            && activeLayout
            && typeof activeLayout.sourceRangeForPage === 'function'
        ) {
            try {
                const sameDocumentRange = activeLayout.sourceRangeForPage(sameDocumentNavigationState.pageIndex)
                if (sameDocumentRange) {
                    range = sameDocumentRange
                }
            } catch (_error) {}
        }

        const index = this._index
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
                const livePageCount = this._getLiveChunkPageCount()
                const adjustForSentinels = MANABI_RENDERER_SENTINEL_ADJUST_ENABLED
                    && livePageCount == null
                    && this._hasSentinels
                    && !this.scrolled
                    && !this._vertical
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
            this._header.style.visibility = pagedDetail.rawPage > 1 ? 'visible' : 'hidden'

            // If layout wasn’t settled yet (common when iframe was hidden pre‑bake),
            // force one re-measure to pick up the real page count.
            if (!this.scrolled && pagedDetail.textPages <= 1) {
                if (this._view) {
                    this._view.cachedViewSize = null
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

        if (activeLayout) {
            activeLayout.setCurrentSourceAnchor?.(range)
            if (reason !== 'selection' && reason !== 'navigation' && reason !== 'anchor') {
                this._anchor = range
            } else {
                this._justAnchored = true
            }
        } else if (reason !== 'selection' && reason !== 'navigation' && reason !== 'anchor') {
            this._anchor = range
        } else {
            this._justAnchored = true
        }

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

        this._relocateGeneration += 1
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
            const livePageCount = this._getLiveChunkPageCount()
            const sentinelAdjusted = MANABI_RENDERER_SENTINEL_ADJUST_ENABLED
                && livePageCount == null
                && !this.scrolled
                && !this._vertical
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
            if (this._touchTriggeredNav) {
                this._logChevronDispatch('sideNavChevronOpacity:startOfSection:skip', {
                    reason: 'navTriggered',
                    bookDir: this.bookDir ?? null,
                    rtl: this._rtl,
                });
            } else {
                this._skipTouchEndOpacity = true
                this._emitChevronOpacity({
                    leftOpacity: this.bookDir === 'rtl' ? 0.999 : 0,
                    rightOpacity: this.bookDir === 'rtl' ? 0 : 0.999,
                }, 'afterScroll:startOfSection');
            }
        }
    }

    _updateSwipeChevron(dx, minSwipe, source = 'swipe') {
        let leftOpacity = 0,
            rightOpacity = 0;
        if (dx > 0) leftOpacity = Math.min(1, dx / minSwipe);
        else if (dx < 0) rightOpacity = Math.min(1, -dx / minSwipe);
        if (leftOpacity > 0 || rightOpacity > 0) {
            this._touchHasShownChevron = true;
        }
        this._maxChevronLeft = Math.max(this._maxChevronLeft, Number(leftOpacity) || 0);
        this._maxChevronRight = Math.max(this._maxChevronRight, Number(rightOpacity) || 0);
        this._emitChevronOpacity({
            leftOpacity,
            rightOpacity,
            fadeMs: this._chevronFadeMs,
        }, source);
    }
    async _display(promise) {
        //            console.log("#display...")
        this._setLoading(true, 'display')
        const {
            index,
            src,
            sectionLocation,
            anchor,
            onLoad,
            select,
            reason,
        } = await promise

        //            console.log("#display...awaited promise")
        this._index = index
        logBug?.('paginator:display:index', {
            index,
            src: src ?? null,
            sectionLocation: sectionLocation ?? null,
            reason: reason ?? null,
            anchor: summarizeAnchor(anchor),
        });
        if (src) {
            const afterLoad = async (doc) => {
                if (this._isCacheWarmer) {
                    await onLoad?.({
                        location: sectionLocation ?? src,
                    })
                } else {
                    hideDocumentContentForPreBake(doc)
                    if (doc.head) {
                        const existingStyles = this._styleMap.get(doc)
                        if (existingStyles) {
                            for (const styleNode of existingStyles) styleNode?.remove?.()
                        }
                        const $styleBefore = doc.createElement('style')
                        doc.head.prepend($styleBefore)
                        const $style = doc.createElement('style')
                        doc.head.append($style)
                        this._styleMap.set(doc, [$styleBefore, $style])
                        if (MANABI_TRACKING_SIZE_BAKE_ENABLED) ensureTrackingSizeBakeStyles(doc)
                    }
                    await onLoad?.({
                        doc,
                        location: sectionLocation ?? src,
                        index,
                    })
                    await this._performTrackingSectionGeometryBake({
                        reason: 'initial-load',
                        restoreLocation: false,
                    })
                    //                    console.log("#display... awaited onLoad")
                }
            }

            if (this._isCacheWarmer) {
                await fetch(src).then(r => r.text())
                await afterLoad()
            } else {
                this._skipTouchEndOpacity = true
                const view = this._createView()
                const beforeRender = this._beforeRender.bind(this)

                this._cachedSizes = null
                this._cachedStart = null
                //                console.log("#display... scrolledToAnchorOnLoad = false")
                this._scrolledToAnchorOnLoad = false

                //                console.log("#display... await load")
                await view.load(src, afterLoad, beforeRender, index, sectionLocation)
                //                console.log("#display... awaited load")
                this._view = view

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

        const layoutSync = await this._syncEbookSectionLayout({
            reason: reason ?? 'display',
            anchor,
        })

        const relocateGenerationBeforeScroll = this._relocateGeneration
        let scrollToAnchorError = null
        try {
            await this.scrollToAnchor(
                (layoutSync?.restoreAnchor ?? this._resolveAnchorAgainstActiveLayout(anchor)) ?? 0,
                select,
                reason
            )
        } catch (error) {
            scrollToAnchorError = error
        }
        const shouldDispatchSyntheticRelocate =
            !this._isCacheWarmer && this._relocateGeneration === relocateGenerationBeforeScroll
        const didDispatchSyntheticRelocate = shouldDispatchSyntheticRelocate
            ? await this._dispatchSyntheticRelocate(reason ?? 'display', scrollToAnchorError)
            : false
        logBug?.('paginator:display:post-scroll', {
            index,
            reason: reason ?? null,
            relocateGenerationBeforeScroll,
            relocateGenerationAfterScroll: this._relocateGeneration,
            shouldDispatchSyntheticRelocate,
            didDispatchSyntheticRelocate,
            scrollToAnchorError: scrollToAnchorError ? String(scrollToAnchorError) : null,
        });
        if (scrollToAnchorError && !didDispatchSyntheticRelocate) {
            throw scrollToAnchorError
        }
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
        this._scrolledToAnchorOnLoad = true
        this._setLoading(false, 'display-complete')
        this._forceEndTouchGesture('didDisplay')
        this.dispatchEvent(new CustomEvent('didDisplay', {}))
        //            console.log("#display... fin")
        return true
    }
    _canGoToIndex(index) {
        return index >= 0 && index <= this.sections.length - 1
    }
    async _goTo({
        index,
        anchor,
        select,
        reason,
    }) {
        //        console.log("#goTo...", this.style.display, index, anchor)
        const navigationReason = reason ?? (select ? 'selection' : 'navigation');
        const willLoadNewIndex = index !== this._index;
        logBug?.('paginator:goTo:start', {
            index,
            currentIndex: this._index,
            willLoadNewIndex,
            reason: navigationReason,
            anchor: summarizeAnchor(anchor),
            hasSelect: !!select,
        });
        this.dispatchEvent(new CustomEvent('goTo', {
            willLoadNewIndex: willLoadNewIndex
        }))
        if (!willLoadNewIndex) {
            await this._display({
                index,
                anchor,
                select,
                reason: navigationReason,
            })
        } else {
            // hide the view until final relocate needs
            this.style.display = 'none'
 
            const oldIndex = this._index
            // Reset direction flags and promise before loading a new section
            this._vertical = this._verticalRTL = this._rtl = null;
            this._directionReady = new Promise(r => (this._directionReadyResolve = r));
            const onLoad = async (detail) => {
                this.sections[oldIndex]?.unload?.()

                if (!this._isCacheWarmer) {
                    this.setStyles(this._styles)
                }

                this.dispatchEvent(new CustomEvent('load', {
                    detail
                }))
            }

            let loadPromise;
            if (this._prefetchCache.has(index)) {
                loadPromise = this._prefetchCache.get(index);
            } else {
                loadPromise = this.sections[index].load();
                this._prefetchCache.set(index, loadPromise);
            }
            await this._display(Promise.resolve(loadPromise)
                .then(src => ({
                    index,
                    src,
                    sectionLocation: this.sections[index]?.id ?? null,
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

            clearTimeout(this._prefetchTimer);
            this._prefetchTimer = setTimeout(() => {
                if (this._index !== index) return; // bail if user has moved on

                const wanted = [index - 1, index + 1];
                // Keep any already cached of these two
                const keep = new Set(wanted.filter(i => this._prefetchCache.has(i)));
                this._prefetchCache = new Map(
                    [...this._prefetchCache].filter(([i]) => keep.has(i))
                );

                // Now prefetch any neighbor not already cached
                wanted.forEach(i => {
                    if (
                        i >= 0 &&
                        i < this.sections.length &&
                        this.sections[i].linear !== 'no' &&
                        !this._prefetchCache.has(i)
                    ) {
                        this._schedulePrefetchLoad(i)
                    }
                });
            }, 500);
        }
    }
    async goTo(target) {
        if (this._locked) {
            const now = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
            const elapsed = now - this._lockTimestamp;
            if (elapsed > 400) {
                this._locked = false;
                logBug?.('paginator:watchdog-unlock-goTo', { elapsedMs: elapsed });
            } else {
                logBug?.('paginator:locked-goTo', { elapsedMs: elapsed });
                return false;
            }
        }
        const resolved = await target
        if (this._canGoToIndex(resolved.index)) return await this._goTo(resolved)
        return false
    }
    async _scrollPrev(distance) {
        if (!this._view) return true
        const livePageCount = this._getLiveChunkPageCount()
        if (!this.scrolled && livePageCount != null && livePageCount <= 1 && this._adjacentIndex(-1) != null) {
            return true
        }
        if (this._usesSameDocumentPagePositioningSync()) {
            let { pageIndex, pageCount } = this._getSameDocumentResolvedNavigationStateSync()
            if (!(pageCount > 0)) return true
            let page = Math.max(0, pageIndex - 1)
            ;({ pageIndex, pageCount } = await this._getSameDocumentPreparedNavigationState(
                page,
                'scrollPrev'
            ))
            page = Math.max(0, pageIndex - 1)
            if (page === pageIndex) return this._adjacentIndex(-1) != null
            return await this._scrollToPage(page, 'page', true).then(() => page <= 0)
        }
        if (this.scrolled) {
            const style = getComputedStyle(this._container);
            const lineAdvance = this._vertical ?
                parseFloat(style.fontSize) || 20 :
                parseFloat(style.lineHeight) || 20;
            const scrollDistance = distance ?? (this.size - lineAdvance);
            if ((await this.start()) > 0) {
                return await this._scrollTo(Math.max(0, this.start - scrollDistance), null, true);
            }
            return true;
        }
        if (await this.atStart()) return
        const page = await this.page() - 1
        return await this._scrollToPage(page, 'page', true).then(() => page <= 0)
    }
    async _scrollNext(distance) {
        if (!this._view) return true
        const livePageCount = this._getLiveChunkPageCount()
        if (!this.scrolled && livePageCount != null && livePageCount <= 1 && this._adjacentIndex(1) != null) {
            return true
        }
        if (this._usesSameDocumentPagePositioningSync()) {
            let { pageIndex, pageCount } = this._getSameDocumentResolvedNavigationStateSync()
            if (!(pageCount > 0)) return true
            let page = Math.min(pageCount - 1, pageIndex + 1)
            ;({ pageIndex, pageCount } = await this._getSameDocumentPreparedNavigationState(
                page,
                'scrollNext'
            ))
            page = Math.min(pageCount - 1, pageIndex + 1)
            setSameDocumentHostTurnDiagnostics({
                phase: 'scroll-next-resolved',
                currentPageIndex: pageIndex,
                pageCount,
                targetPageIndex: page,
            })
            if (page === pageIndex) return this._adjacentIndex(1) != null
            return await this._scrollToPage(page, 'page', true).then(() => page >= pageCount - 1)
        }
        if (this.scrolled) {
            const style = getComputedStyle(this._container);
            const lineAdvance = this._vertical ?
                parseFloat(style.fontSize) || 20 :
                parseFloat(style.lineHeight) || 20;
            const scrollDistance = distance ?? (this.size - lineAdvance);
            if ((await this.viewSize()) - (await this.end()) > 2) {
                return await this._scrollTo(Math.min(await this.viewSize(), (await this.start()) + scrollDistance), null, true);
            }
            return true;
        }
        if (await this.atEnd()) return
        const page = await this.page() + 1
        const pages = await this.pages()
        return await this._scrollToPage(page, 'page', true).then(() => page >= pages - 1)
    }
    async atStart() {
        const livePageCount = this._getLiveChunkPageCount()
        const edgePage = livePageCount != null ? 0 : 1
        return this._adjacentIndex(-1) == null && (await this.page()) <= edgePage
    }
    async atEnd() {
        const livePageCount = this._getLiveChunkPageCount()
        const edgeOffset = livePageCount != null ? 1 : 2
        return this._adjacentIndex(1) == null && (await this.page()) >= (await this.pages()) - edgeOffset
    }
    _adjacentIndex(dir) {
        for (let index = this._index + dir; this._canGoToIndex(index); index += dir)
            if (this.sections[index]?.linear !== 'no') return index
    }
    async _turnPage(dir, distance) {
        if (this._locked) {
            const now = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
            const elapsed = now - this._lockTimestamp;
            if (elapsed > 400) {
                this._locked = false;
                logBug?.('paginator:watchdog-unlock-turnPage', { dir, elapsedMs: elapsed });
            } else {
                logBug?.('paginator:locked-turnPage', { dir, elapsedMs: elapsed });
                return false;
            }
        }

        this._locked = true
        this._lockTimestamp = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
        const beforeIndex = this._index
        const beforePage = await this.page().catch(() => null)
        const beforePages = await this.pages().catch(() => null)
        const adjacentIndex = this._adjacentIndex(dir)
        logBug?.('paginator:turnPage:start', {
            dir,
            distance,
            currentIndex: beforeIndex,
            adjacentIndex,
            beforePage,
            beforePages,
        });
        try {
            const prev = dir === -1
            const shouldGo = await (prev ? await this._scrollPrev(distance) : await this._scrollNext(distance))
            logBug?.('paginator:turnPage:shouldGo', {
                dir,
                shouldGo,
                currentIndex: this._index,
                adjacentIndex,
            });
            let didNavigate = false
            if (shouldGo) {
                logBug?.('paginator:turnPage:cross-section', {
                    dir,
                    currentIndex: this._index,
                    targetIndex: adjacentIndex,
                });
                didNavigate = await this._goTo({
                    index: adjacentIndex,
                    anchor: prev ? () => 1 : () => 0,
                    reason: 'page',
                })
            }
            if (shouldGo || !this.hasAttribute('animated')) {
                await wait(100)
            }
            const afterPage = await this.page().catch(() => null)
            const afterPages = await this.pages().catch(() => null)
            const resolved = didNavigate
                || this._index !== beforeIndex
                || beforePage !== afterPage
                || beforePages !== afterPages
            return resolved
        } finally {
            // Never leave the paginator locked if navigation threw/cancelled.
            this._locked = false
            const afterPage = await this.page().catch(() => null)
            const afterPages = await this.pages().catch(() => null)
            logBug?.('paginator:turnPage:end', {
                dir,
                currentIndex: this._index,
                afterPage,
                afterPages,
            });
        }
    }
    async prev(distance) {
        return await this._turnPage(-1, distance)
    }
    async next(distance) {
        return await this._turnPage(1, distance)
    }
    hostTurn(direction) {
        const dir = direction === 'backward' ? -1 : 1
        if (this._usesSameDocumentPagePositioningSync()) {
            return Promise.resolve().then(async () => {
                let { pageIndex: currentPage, pageCount } = this._getSameDocumentResolvedNavigationStateSync()
                let targetPage = currentPage + dir
                ;({ pageIndex: currentPage, pageCount } = await this._getSameDocumentPreparedNavigationState(
                    targetPage,
                    'host-turn'
                ))
                targetPage = currentPage + dir
                setSameDocumentHostTurnDiagnostics({
                    phase: 'host-turn-begin',
                    direction,
                    currentPageIndex: currentPage,
                    pageCount,
                    targetPageIndex: targetPage,
                })
                if (targetPage >= 0 && targetPage < pageCount) {
                    await this._scrollToPage(targetPage, 'host-turn', false)
                    const settledState = this._getSameDocumentResolvedNavigationStateSync()
                    const settledPageIndex = settledState.pageIndex
                    const settledPageCount = settledState.pageCount
                    setSameDocumentHostTurnDiagnostics({
                        phase: settledPageIndex === targetPage ? 'host-turn-complete' : 'host-turn-stalled',
                        direction,
                        currentPageIndex: settledPageIndex,
                        pageCount: settledPageCount,
                        targetPageIndex: targetPage,
                        result: settledPageIndex === targetPage ? 'page' : 'stalled',
                    })
                    return settledPageIndex === targetPage
                }
                const adjacentIndex = this._adjacentIndex(dir)
                if (adjacentIndex != null) {
                    setSameDocumentHostTurnDiagnostics({
                        phase: 'host-turn-section',
                        direction,
                        currentPageIndex: currentPage,
                        pageCount,
                        adjacentSectionIndex: adjacentIndex,
                        result: 'section',
                    })
                    return this._goTo({
                        index: adjacentIndex,
                        anchor: dir < 0 ? () => 1 : () => 0,
                        reason: 'page',
                    })
                }
                setSameDocumentHostTurnDiagnostics({
                    phase: 'host-turn-unavailable',
                    direction,
                    currentPageIndex: currentPage,
                    pageCount,
                    targetPageIndex: targetPage,
                    result: 'unavailable',
                })
                return false
            })
        }
        return dir < 0
            ? this.prev()
            : this.next()
    }
    async prevSection() {
        const targetIndex = this._adjacentIndex(-1)
        logBug?.('paginator:prevSection', {
            currentIndex: this._index,
            targetIndex,
        });
        return await this.goTo({
            index: targetIndex,
            reason: 'page',
        })
    }
    async nextSection() {
        const targetIndex = this._adjacentIndex(1)
        logBug?.('paginator:nextSection', {
            currentIndex: this._index,
            targetIndex,
        });
        return await this.goTo({
            index: targetIndex,
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
        if (this._view) return [{
            index: this._index,
            overlayer: this._view.overlayer,
            doc: this._view.document,
        }]
        return []
    }
    setStyles(styles) {
        this._styles = styles
        const $$styles = this._styleMap.get(this._view?.document)
        if (!$$styles) return
        const [$beforeStyle, $style] = $$styles
        if (Array.isArray(styles)) {
            const [beforeStyle, style] = styles
            $beforeStyle.textContent = beforeStyle
            $style.textContent = style
        } else $style.textContent = styles

        //        // NOTE: needs `requestAnimationFrame` in Chromium
        //        requestAnimationFrame(() =>
        //            this._background.style.background = getBackground(this._view.document))

        // needed because the resize observer doesn't work in Firefox
        //            this._view?.document?.fonts?.ready?.then(async () => { await this._view.expand() })

        this.requestTrackingSectionSizeBake({ reason: 'styles-applied' })
    }
    destroy() {
        this._disconnectElementVisibilityObserver()
        this._resizeObserver.unobserve(this)
        this._resetTrackingSectionSizeState()
        this._bindEbookLayoutEvents(null)
        this._ebookSectionLayout.destroy()
        this._view.destroy()
        this._view = null
        this._teardownSameDocumentViewport()
        this.sections[this._index]?.unload?.()
    }
    // Public navigation edge detection methods
    async canTurnPrev() {
        if (!this._view) return false;
        if (this.scrolled) {
            return this.start > 0;
        }
        // If at the start page and no previous section, cannot turn
        const livePageCount = this._getLiveChunkPageCount();
        const edgePage = livePageCount != null ? 0 : 1;
        if ((await this.page()) <= edgePage && this._adjacentIndex(-1) == null) return false;
        return true;
    }
    async canTurnNext() {
        if (!this._view) return false;
        if (this.scrolled) {
            return this.viewSize - this.end > 2;
        }
        // If at the end page and no next section, cannot turn
        const livePageCount = this._getLiveChunkPageCount();
        const edgeOffset = livePageCount != null ? 1 : 2;
        if ((await this.page()) >= (await this.pages()) - edgeOffset && this._adjacentIndex(1) == null) return false;
        return true;
    }

    debugVisualDiagnostics() {
        const roundRect = rect => rect ? {
            top: Math.round(rect.top),
            left: Math.round(rect.left),
            width: Math.round(rect.width),
            height: Math.round(rect.height),
        } : null
        const styleValue = (node, key) => {
            try {
                if (!node) return null
                return getComputedStyle(node)?.[key] ?? null
            } catch (_error) {
                return null
            }
        }
        const infoFor = node => ({
            tag: node?.tagName?.toLowerCase?.() ?? null,
            id: node?.id ?? null,
            className: typeof node?.className === 'string' ? node.className : null,
        })
        const doc = this._view?.document ?? null
        const stage = document.getElementById('reader-stage')
        const viewport = document.getElementById('manabi-same-document-viewport')
        const viewportContainer = document.getElementById('manabi-same-document-container')
        const contentRoot = this._view?.document
            ? (this._view.document.getElementById?.('reader-content') || this._view.document.body || null)
            : null
        const liveRoot = contentRoot?.querySelector?.('.manabi-page-root') || null
        const livePages = liveRoot ? Array.from(liveRoot.querySelectorAll(':scope > .manabi-page')) : []
        const firstLivePage = livePages[0] || null
        const secondLivePage = livePages[1] || null
        const lastLivePage = livePages[livePages.length - 1] || null
        const sumLivePageWidths = livePages.reduce((sum, node) => {
            try {
                return sum + (node?.getBoundingClientRect?.().width || 0)
            } catch (_error) {
                return sum
            }
        }, 0)
        const elementCenter = node => {
            if (!node?.getBoundingClientRect) return null
            try {
                const rect = node.getBoundingClientRect()
                const x = Math.round(rect.left + rect.width / 2)
                const y = Math.round(rect.top + rect.height / 2)
                return document.elementFromPoint(x, y)
            } catch (_error) {
                return null
            }
        }
        return {
            sameDocumentMode: this._sameDocumentMode,
            hostDisplay: styleValue(this, 'display'),
            hostVisibility: styleValue(this, 'visibility'),
            hostOpacity: styleValue(this, 'opacity'),
            hostRect: roundRect(this.getBoundingClientRect?.()),
            topDisplay: styleValue(this._top, 'display'),
            topVisibility: styleValue(this._top, 'visibility'),
            topOpacity: styleValue(this._top, 'opacity'),
            topRect: roundRect(this._top?.getBoundingClientRect?.()),
            containerDisplay: styleValue(this._container, 'display'),
            containerVisibility: styleValue(this._container, 'visibility'),
            containerOpacity: styleValue(this._container, 'opacity'),
            containerRect: roundRect(this._container?.getBoundingClientRect?.()),
            containerClientWidth: this._container?.clientWidth ?? null,
            containerClientHeight: this._container?.clientHeight ?? null,
            containerScrollWidth: this._container?.scrollWidth ?? null,
            containerScrollHeight: this._container?.scrollHeight ?? null,
            sameDocumentViewportExists: !!viewport,
            sameDocumentViewportRect: roundRect(viewport?.getBoundingClientRect?.()),
            sameDocumentViewportDisplay: styleValue(viewport, 'display'),
            sameDocumentViewportVisibility: styleValue(viewport, 'visibility'),
            sameDocumentViewportOpacity: styleValue(viewport, 'opacity'),
            sameDocumentViewportZIndex: styleValue(viewport, 'zIndex'),
            sameDocumentViewportPointerEvents: styleValue(viewport, 'pointerEvents'),
            sameDocumentViewportParentTag: viewport?.parentElement?.tagName?.toLowerCase?.() ?? null,
            sameDocumentViewportParentId: viewport?.parentElement?.id ?? null,
            sameDocumentContainerExists: !!viewportContainer,
            sameDocumentContainerRect: roundRect(viewportContainer?.getBoundingClientRect?.()),
            sameDocumentContainerDisplay: styleValue(viewportContainer, 'display'),
            sameDocumentContainerVisibility: styleValue(viewportContainer, 'visibility'),
            sameDocumentContainerOpacity: styleValue(viewportContainer, 'opacity'),
            mountRect: roundRect(this._view?.element?.getBoundingClientRect?.()),
            mountDisplay: styleValue(this._view?.element, 'display'),
            mountVisibility: styleValue(this._view?.element, 'visibility'),
            mountOpacity: styleValue(this._view?.element, 'opacity'),
            mountBackgroundColor: styleValue(this._view?.element, 'backgroundColor'),
            stageRect: roundRect(stage?.getBoundingClientRect?.()),
            stageDisplay: styleValue(stage, 'display'),
            stageVisibility: styleValue(stage, 'visibility'),
            stageOpacity: styleValue(stage, 'opacity'),
            stageZIndex: styleValue(stage, 'zIndex'),
            stageBackgroundColor: styleValue(stage, 'backgroundColor'),
            shellCenterElementTag: infoFor(elementCenter(stage || viewport || this._container)).tag,
            shellCenterElementId: infoFor(elementCenter(stage || viewport || this._container)).id,
            shellCenterElementClassName: infoFor(elementCenter(stage || viewport || this._container)).className,
            documentURL: doc?.URL ?? null,
            documentReadyState: doc?.readyState ?? null,
            documentBodyTextLength: doc?.body?.innerText?.trim?.().length ?? null,
            documentBodyColor: styleValue(doc?.body, 'color'),
            documentBodyBackgroundColor: styleValue(doc?.body, 'backgroundColor'),
            contentRootRect: roundRect(contentRoot?.getBoundingClientRect?.()),
            contentRootTextLength: contentRoot?.innerText?.trim?.().length ?? null,
            contentRootDisplay: styleValue(contentRoot, 'display'),
            contentRootVisibility: styleValue(contentRoot, 'visibility'),
            contentRootOpacity: styleValue(contentRoot, 'opacity'),
            liveRootClientWidth: liveRoot?.clientWidth ?? null,
            liveRootClientHeight: liveRoot?.clientHeight ?? null,
            liveRootScrollWidth: liveRoot?.scrollWidth ?? null,
            liveRootScrollHeight: liveRoot?.scrollHeight ?? null,
            liveRootTransform: styleValue(liveRoot, 'transform'),
            liveRootTransition: styleValue(liveRoot, 'transition'),
            liveRootDatasetCurrentPageIndex: liveRoot?.dataset?.manabiCurrentPageIndex ?? null,
            sameDocumentHostTurnPhase: globalThis.manabiSameDocumentHostTurnDiagnostics?.phase ?? null,
            sameDocumentHostTurnDirection: globalThis.manabiSameDocumentHostTurnDiagnostics?.direction ?? null,
            sameDocumentHostTurnCurrentPageIndex: globalThis.manabiSameDocumentHostTurnDiagnostics?.currentPageIndex ?? null,
            sameDocumentHostTurnTargetPageIndex: globalThis.manabiSameDocumentHostTurnDiagnostics?.targetPageIndex ?? null,
            sameDocumentHostTurnPageCount: globalThis.manabiSameDocumentHostTurnDiagnostics?.pageCount ?? null,
            sameDocumentHostTurnTargetOffset: globalThis.manabiSameDocumentHostTurnDiagnostics?.targetOffset ?? null,
            sameDocumentHostTurnAppliedTransform: globalThis.manabiSameDocumentHostTurnDiagnostics?.appliedTransform ?? null,
            sameDocumentHostTurnDatasetCurrentPageIndex: globalThis.manabiSameDocumentHostTurnDiagnostics?.datasetCurrentPageIndex ?? null,
            sameDocumentHostTurnResult: globalThis.manabiSameDocumentHostTurnDiagnostics?.result ?? null,
            liveRootComputedWidth: styleValue(liveRoot, 'width'),
            liveRootComputedMinWidth: styleValue(liveRoot, 'minWidth'),
            liveRootComputedMaxWidth: styleValue(liveRoot, 'maxWidth'),
            liveRootComputedInlineSize: styleValue(liveRoot, 'inlineSize'),
            liveRootComputedMinInlineSize: styleValue(liveRoot, 'minInlineSize'),
            liveRootComputedMaxInlineSize: styleValue(liveRoot, 'maxInlineSize'),
            liveRootComputedOverflowX: styleValue(liveRoot, 'overflowX'),
            livePageCountFromDOM: livePages.length,
            livePageWidthSum: Math.round(sumLivePageWidths),
            firstLivePageRect: roundRect(firstLivePage?.getBoundingClientRect?.()),
            secondLivePageRect: roundRect(secondLivePage?.getBoundingClientRect?.()),
            lastLivePageRect: roundRect(lastLivePage?.getBoundingClientRect?.()),
            firstLivePageOffsetLeft: firstLivePage?.offsetLeft ?? null,
            secondLivePageOffsetLeft: secondLivePage?.offsetLeft ?? null,
            lastLivePageOffsetLeft: lastLivePage?.offsetLeft ?? null,
            firstLivePageComputedWidth: styleValue(firstLivePage, 'width'),
            lastLivePageComputedWidth: styleValue(lastLivePage, 'width'),
        }
    }

    // Public helpers for adjacent sections
    getHasPrevSection() {
        return this._adjacentIndex(-1) != null;
    }
    getHasNextSection() {
        return this._adjacentIndex(1) != null;
    }

    // Public: At first page of current section
    async isAtSectionStart() {
        const livePageCount = this._getLiveChunkPageCount()
        return (await this.page()) <= (livePageCount != null ? 0 : 1);
    }
    // Public: At last page of current section
    async isAtSectionEnd() {
        const livePageCount = this._getLiveChunkPageCount()
        const edgeOffset = livePageCount != null ? 1 : 2
        return (await this.page()) >= (await this.pages()) - edgeOffset;
    }
}

customElements.define('foliate-paginator', Paginator)
