// Global timers for side-nav chevron fades
import './view.js'
import {
createTOCView
} from './ui/tree.js'
import { NavigationHUD } from './ebook-viewer-nav.js'

const DEFAULT_RUBY_FONT_STACK = `'Hiragino Kaku Gothic ProN', 'Hiragino Sans', system-ui`;

// pagination logger disabled for noise reduction
const logEBookPagination = () => {};

// Perf logger (disabled)
const logEBookPerf = (event, detail = {}) => ({ event, ...detail });

const VIEWER_PAGE_NUM_WHITELIST = new Set([
    'relocate',
    'relocate:label',
    'nav:set-page-targets',
]);

const logFix = (event, detail = {}) => {
    try {
        const payload = { event, ...detail };
        window.webkit?.messageHandlers?.print?.postMessage?.(`# EBOOKFIX1 ${JSON.stringify(payload)}`);
    } catch (_err) {
        try { console.log('# EBOOKFIX1', event, detail); } catch (_) {}
    }
};

const logBug = (event, detail = {}) => {
    try {
        const payload = { event, ...detail };
        window.webkit?.messageHandlers?.print?.postMessage?.(`# BOOKBUG1 ${JSON.stringify(payload)}`);
    } catch (_err) {
        try { console.log('# BOOKBUG1', event, detail); } catch (_) {}
    }
};

const EBOOK_HTML_MARKER = '芥川賞';
const EBOOK_HTML_TARGET_HREFS = [
    'item/xhtml/title.xhtml',
    'item/xhtml/0001.xhtml',
];
const EBOOK_HTML_VERBOSE_DUMP = false;

const logEBookHTMLLine = (line) => {
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_err) {
        try { console.log(line); } catch (_) {}
    }
};

const maybeLogEBookHTML = (
    stage,
    {
        href = null,
        mediaType = null,
        isCacheWarmer = null,
        html = null,
        force = false,
    } = {}
) => {
    if (typeof html !== 'string') return false;
    const normalizedHref = typeof href === 'string' ? href : '';
    const isTargetHref = EBOOK_HTML_TARGET_HREFS.some((fragment) => normalizedHref.includes(fragment));
    const hasMarker = html.includes(EBOOK_HTML_MARKER);
    if (!force && !hasMarker && !isTargetHref) return false;
    logEBookHTMLLine(`# EBOOKHTML ${JSON.stringify({
        stage,
        href,
        mediaType,
        isCacheWarmer,
        length: html.length,
        segmentCount: (html.match(/<manabi-segment(\s|>)/g) || []).length,
        hasMarker,
        isTargetHref,
        force,
    })}`);
    if (EBOOK_HTML_VERBOSE_DUMP) {
        logEBookHTMLLine(`# EBOOKHTML stage=${stage} verboseDumpDisabled=false`);
        logEBookHTMLLine(html);
    }
    return true;
};
globalThis.manabiMaybeLogEBookHTML = maybeLogEBookHTML;

const logNavHide = (event, detail = {}) => {
    const payload = { event, ...detail };
    const line = `# EBOOK NAVHIDE ${JSON.stringify(payload)}`;
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (_err) {
        try { console.log(line); } catch (_) {}
    }
};

const MANABI_TRACKING_CACHE_HANDLER = globalThis.MANABI_TRACKING_CACHE_HANDLER || 'trackingSizeCache';
globalThis.MANABI_TRACKING_CACHE_HANDLER = MANABI_TRACKING_CACHE_HANDLER;

const getBookCacheKey = () => {
    try {
        return globalThis.reader?.view?.book?.id
            || new URL(globalThis.reader?.view?.ownerDocument?.defaultView?.location?.href || '').pathname
            || globalThis.reader?.view?.book?.dir
            || null;
    } catch (_) { return null; }
};

const getCacheWarmerSectionPageCounts = () => {
    const map = globalThis.cacheWarmerPageCounts;
    if (map instanceof Map) return map;
    if (Array.isArray(map)) return new Map(map);
    return null;
};

const logEBookPageNum = (event, detail = {}) => {
    const verbose = !!globalThis.manabiPageNumVerbose;
    const allow = verbose || VIEWER_PAGE_NUM_WHITELIST.has(event);
    if (!allow) return;
    try {
        const payload = { event, ...detail };
        const line = `# EBOOKK PAGENUM ${JSON.stringify(payload)}`;
        globalThis.window?.webkit?.messageHandlers?.print?.postMessage?.(line);
    } catch (error) {
        try {
            console.log('# EBOOKK PAGENUM fallback', event, detail, error);
        } catch (_) {}
    }
};

// Shared font blob support: the native viewer injects base64 CSS into the shell once.
const getSharedFontCSSText = () => {
    if (globalThis.manabiFontCSSText) return globalThis.manabiFontCSSText;
    const base64 =
        globalThis.manabiFontCSSBase64 ||
        globalThis.parent?.manabiFontCSSBase64 ||
        globalThis.top?.manabiFontCSSBase64 ||
        document.getElementById('manabi-font-css-base64')?.textContent ||
        '';
    if (!base64) return null;
    try {
        const css = atob(base64);
        globalThis.manabiFontCSSText = css;
        return css;
    } catch (_err) {
        logEBookPerf('font-css-decode-error', {});
        return null;
    }
};

const waitForFontCSSReady = async (timeoutMs = 2000) => {
    const start = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
    let css = getSharedFontCSSText();
    while (!css) {
        const now = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
        if (now - start >= timeoutMs) break;
        await new Promise(resolve => requestAnimationFrame(resolve));
        css = getSharedFontCSSText();
    }
    if (!css) logEBookPerf('font-css-timeout', { waitedMs: ((typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now()) - start });
    return css;
};

const ensureCustomFontsForDoc = async (doc) => {
    try {
        const root = doc?.documentElement;
        if (globalThis.manabiDisableCustomFonts === true) {
            if (root) {
                delete root.dataset.manabiFontPending;
                root.dataset.manabiFontReady = 'skipped';
            }
            return false;
        }
        const css = await waitForFontCSSReady(4000);
        if (!css || !doc?.head) return false;
        const horizontalFamily = globalThis.manabiHorizontalFontFamilyName || 'YuKyokasho Yoko';
        const verticalFamily = globalThis.manabiVerticalFontFamilyName || 'YuKyokasho';
        const writingDirection = globalThis.manabiEbookWritingDirection || 'original';
        const shouldUseVertical = writingDirection === 'vertical'
            || (writingDirection === 'original' && globalThis.manabiTrackingVertical === true);
        const targetFamily = shouldUseVertical ? verticalFamily : horizontalFamily;
        if (root) {
            root.dataset.manabiFontPending = '1';
            root.dataset.manabiFontReady = '0';
        }
        let style = doc.getElementById('manabi-custom-fonts-inline');
        if (!style) {
            style = doc.createElement('link');
            style.id = 'manabi-custom-fonts-inline';
            style.rel = 'stylesheet';
            doc.head.appendChild(style);
            logEBookPerf('font-inline-insert', { bytes: css.length, mode: 'blob-link' });
        }
        if (style.dataset.manabiInjectedFontFamily !== targetFamily || !style.href) {
            const sourceCSS = globalThis.manabiFontCSSText || css;
            const nextCSS = sourceCSS.replace(
                /font-family:\s*['"][^'"]+['"]\s*;/g,
                "font-family: '" + targetFamily + "';"
            );
            const blob = new Blob([nextCSS], { type: 'text/css' });
            const nextBlobURL = URL.createObjectURL(blob);
            const previousBlobURL = style.dataset.manabiBlobURL || '';
            style.href = nextBlobURL;
            style.dataset.manabiBlobURL = nextBlobURL;
            style.dataset.manabiInjectedFontFamily = targetFamily;
            if (previousBlobURL && previousBlobURL !== nextBlobURL) {
                try { URL.revokeObjectURL(previousBlobURL); } catch (_error) {}
            }
        }

        const fontSet = doc.fonts;
        if (fontSet) {
            try {
                if (typeof fontSet.load === 'function') {
                    await fontSet.load("1em '" + targetFamily + "'");
                }
            } catch (_error) {}
            try {
                if (typeof fontSet.ready === 'object' && fontSet.ready && typeof fontSet.ready.then === 'function') {
                    await fontSet.ready;
                }
            } catch (_error) {}
            const size = fontSet?.size ?? null;
            logEBookPerf('fontset-ready-iframe', {
                status: fontSet?.status ?? 'unknown',
                size,
                family: targetFamily
            });
        }
        if (root) {
            delete root.dataset.manabiFontPending;
            root.dataset.manabiFontReady = '1';
        }
        return true;
    } catch (_err) {
        try {
            const root = doc?.documentElement;
            if (root) {
                delete root.dataset.manabiFontPending;
                root.dataset.manabiFontReady = '0';
            }
        } catch (__error) {}
        return false;
    }
};

globalThis.manabiWaitForFontCSS = waitForFontCSSReady;
globalThis.manabiEnsureCustomFonts = ensureCustomFontsForDoc;

const MAX_ERROR_LENGTH = 4000;
const ERROR_TRUNCATION_SUFFIX = '...(truncated)';

const clampErrorString = (value) => {
    if (value === null || value === undefined) return null;
    const text = String(value);
    if (text.length <= MAX_ERROR_LENGTH) return text;
    const headLength = Math.max(0, MAX_ERROR_LENGTH - ERROR_TRUNCATION_SUFFIX.length);
    return text.slice(0, headLength) + ERROR_TRUNCATION_SUFFIX;
};

const sanitizeErrorValue = (value) => {
    if (value === null || value === undefined) return null;
    const t = typeof value;
    if (t === 'string' || t === 'number' || t === 'boolean') return clampErrorString(value);
    try {
        if (value instanceof Error) {
            return clampErrorString(value.stack || value.message || String(value));
        }
    } catch (_) {}
    try {
        const name = value?.name;
        const message = value?.message;
        const code = value?.code;
        const stack = value?.stack;
        const parts = [];
        if (name) parts.push(String(name));
        if (message) parts.push(String(message));
        if (code !== undefined && code !== null) parts.push(`code=${code}`);
        if (stack) parts.push(String(stack));
        if (parts.length) return clampErrorString(parts.join(' | '));
    } catch (_) {}
    try {
        return clampErrorString(String(value));
    } catch (_) {
        return 'unknown-error';
    }
};

const postReaderOnError = (payload) => {
    try {
        window.webkit?.messageHandlers?.readerOnError?.postMessage?.(payload);
    } catch (_error) {
        // ignore to avoid recursive crash loops
    }
};

window.onerror = function(msg, source, lineno, colno, error) {
    const safeMessage = sanitizeErrorValue(msg) ?? 'Unknown error';
    const safeSource = sanitizeErrorValue(source);
    const safeError = sanitizeErrorValue(error);
    postReaderOnError({
        message: safeMessage,
        source: safeSource,
        lineno: lineno,
        colno: colno,
        error: safeError
    });
};

window.onunhandledrejection = function(event) {
    const safeMessage = sanitizeErrorValue(event.reason?.message) ?? "Unhandled rejection";
    const safeError = sanitizeErrorValue(event.reason?.stack ?? event.reason);
    postReaderOnError({
        message: safeMessage,
        source: window.location.href,
        lineno: null,
        colno: null,
        error: safeError
    });
};

function forwardShadowErrors(root) {
    if (!root) return;
    root.addEventListener('error', e => {
        const safeMessage = sanitizeErrorValue(e.message || e.error?.message) ?? 'Shadow-DOM error';
        const safeError = sanitizeErrorValue(e.error || e);
        postReaderOnError({
            message: safeMessage,
            source: window.location.href,
            lineno: e.lineno || 0,
            colno: e.colno || 0,
            error: safeError
        });
    });
    root.addEventListener('unhandledrejection', e => {
        const safeMessage = sanitizeErrorValue(e.reason?.message) ?? 'Shadow-DOM unhandled rejection';
        const safeError = sanitizeErrorValue(e.reason?.stack ?? e.reason);
        postReaderOnError({
            message: safeMessage,
            source: window.location.href,
            lineno: 0,
            colno: 0,
            error: safeError
        });
    });
}

const installFontDiagnostics = () => {
try {
const fontSet = document?.fonts
if (!fontSet?.addEventListener) return

const serializeFace = face => ({
family: face?.family || null,
weight: face?.weight || null,
style: face?.style || null,
stretch: face?.stretch || null,
status: face?.status || null,
display: face?.display || null,
})
const logFaces = (event, faces) => {
const arr = Array.from(faces ?? []).map(serializeFace)
logEBookPerf(event, {
count: arr.length,
status: fontSet.status,
faces: arr,
})
}

fontSet.addEventListener('loading', e => logFaces('fontset-loading', e?.fontfaces))
fontSet.addEventListener('loadingdone', e => logFaces('fontset-loadingdone', e?.fontfaces))
fontSet.addEventListener('loadingerror', e => logFaces('fontset-loadingerror', e?.fontfaces))
fontSet.ready?.then?.(() => {
logEBookPerf('fontset-ready', { status: fontSet.status, size: fontSet.size })
}).catch(() => {})
} catch (_error) {
// diagnostics best-effort
}
}

installFontDiagnostics()

let pendingHideNavigationState = null;
let navHideLock = false;

const applyLocalHideNavigationDueToScroll = (shouldHide, source = 'unknown') => {
    const appliedHide = !!shouldHide;
    pendingHideNavigationState = appliedHide;
    logNavHide('apply-local', {
        requested: !!shouldHide,
        applied: appliedHide,
        source,
        hasReader: !!globalThis.reader,
    });
    if (globalThis.reader?.setHideNavigationDueToScroll) {
        globalThis.reader.setHideNavigationDueToScroll(appliedHide, source);
        pendingHideNavigationState = null;
    }
};
globalThis.manabiSetHideNavigationDueToScroll = applyLocalHideNavigationDueToScroll;

globalThis.manabiToggleReaderTableOfContents = () => {
    try {
    if (globalThis.reader?.toggleTableOfContents) {
    globalThis.reader.toggleTableOfContents();
    }
    } catch (error) {
    console.error('Failed to toggle table of contents', error);
    }
};

const updateNavHiddenClass = (shouldHide) => {
    try {
    const hide = !!shouldHide;
    document?.body?.classList.toggle('nav-hidden', hide);
    // Inform the navigation HUD so it can pick compact/full label.
    globalThis.reader?.navHUD?.setNavHiddenState?.(hide);
    const navPrimaryText = document.getElementById('nav-primary-text');
    if (navPrimaryText?.dataset) {
        navPrimaryText.dataset.labelVariant = hide ? 'compact' : 'full';
    }
    } catch (_error) {
    // best-effort
    }
};

const postNavigationChromeVisibility = (shouldHide, { source, direction, scrubbing = false, ctx = null } = {}) => {
    navHideLock = false;
    const appliedHide = !!shouldHide;

    const payload = { requested: !!shouldHide, applied: appliedHide, source, direction, scrubbing, navHideLock };
    if (ctx && typeof ctx === 'object') {
        payload.sectionIndex = ctx.sectionIndex ?? null;
        payload.fraction = ctx.fraction ?? null;
        payload.previousFraction = ctx.previousFraction ?? null;
        payload.reason = ctx.reason ?? null;
    }
    logNavHide('nav-visibility', payload);
    logBug('nav-visibility', payload);
    applyLocalHideNavigationDueToScroll(appliedHide, source ?? 'nav-visibility');
    try {
        window.webkit?.messageHandlers?.ebookNavigationVisibility?.postMessage?.({
            hideNavigationDueToScroll: appliedHide,
            source: source ?? null,
            direction: direction ?? null,
        });
    } catch (error) {
        console.error('Failed to notify native navigation chrome visibility', error);
    }
    updateNavHiddenClass(appliedHide);
};

// Factory for replaceText with isCacheWarmer support
const makeReplaceText = (isCacheWarmer) => async (href, text, mediaType) => {
    if (mediaType !== 'application/xhtml+xml' && mediaType !== 'text/html' /* && mediaType !== 'application/xml'*/ ) {
        return text;
    }
    const shouldForceHTMLLogging = maybeLogEBookHTML('js.replaceText.requestRaw', {
        href,
        mediaType,
        isCacheWarmer,
        html: text,
    });
    const contentLocation =
        globalThis.reader?.view?.ownerDocument?.defaultView?.top?.location?.href
        || globalThis.location?.href
        || ""
    const shouldFailOpenFast =
        contentLocation.includes('ui-test-page-turn.epub')
        || globalThis.manabiPageTurnInteractionDiagnostic === true
    if (shouldFailOpenFast) {
        globalThis.manabiLoadEBookLastState = `replace-text-skip-original:${href}`
        logEBookPerf('replace-text-skip-original', {
            href,
            isCacheWarmer,
            mediaType,
            bodyLength: text?.length ?? 0,
        })
        return text
    }
    const replaceTextTimeoutMs = shouldFailOpenFast ? 1200 : 5000
    const headers = {
        "Content-Type": mediaType,
        "X-Replaced-Text-Location": href,
        "X-Content-Location": contentLocation,
    };
    if (isCacheWarmer) {
        headers['X-Is-Cache-Warmer'] = 'true';
    }
    const perfStart = (typeof performance !== 'undefined' && typeof performance.now === 'function')
        ? performance.now()
        : Date.now();
    logEBookPerf('replace-text-request', {
        href,
        isCacheWarmer,
        mediaType,
        bodyLength: text?.length ?? 0,
    })
    globalThis.manabiLoadEBookLastState = `replace-text-awaiting-response:${href}`
    const response = await Promise.race([
        fetch('ebook://ebook/process-text', {
            method: "POST",
            mode: "cors",
            cache: "no-cache",
            headers: headers,
            body: text
        }),
        timeoutPromise(replaceTextTimeoutMs, `replace-text-timeout:${href}`),
    ])
    try {
    if (!response.ok) {
    throw new Error(`HTTP error, status = ${response.status}`)
    }
    globalThis.manabiLoadEBookLastState = `replace-text-response-ready:${href}`
    const durationMs = (typeof performance !== 'undefined' && typeof performance.now === 'function')
    ? performance.now() - perfStart
    : null
    logEBookPerf('replace-text-response', {
    href,
    isCacheWarmer,
    status: response.status,
    durationMs,
    })
    globalThis.manabiLoadEBookLastState = `replace-text-decoding-response:${href}`
    let html = await Promise.race([
    response.text(),
    timeoutPromise(5000, `replace-text-response-body-timeout:${href}`),
    ])
    globalThis.manabiLoadEBookLastState = `replace-text-response-decoded:${href}`
    maybeLogEBookHTML('js.replaceText.responseProcessed', {
    href,
    mediaType,
    isCacheWarmer,
    html,
    force: shouldForceHTMLLogging,
    });
    if (isCacheWarmer && html.replace) {
    html = html.replace(/<body\s/i, "<body data-is-cache-warmer='true' ")
    }
    return html
    } catch (error) {
    const durationMs = (typeof performance !== 'undefined' && typeof performance.now === 'function')
    ? performance.now() - perfStart
    : null
    logEBookPerf('replace-text-error', {
    href,
    isCacheWarmer,
    message: error?.message || String(error),
    durationMs,
    })
    if (shouldFailOpenFast && String(error?.message || error).startsWith('replace-text-timeout:')) {
    globalThis.manabiLoadEBookLastState = `replace-text-fallback-original:${href}`
    return text
    }
    console.error("Error replacing text:", error)
    return text
    }
}

// https://learnersbucket.com/examples/interview/debouncing-with-leading-and-trailing-options/
const debounce = (fn, delay) => {
    let timeout;
    let isLeadingInvoked = false;

    return function(...args) {
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

const isZip = async file => {
    const arr = new Uint8Array(await file.slice(0, 4).arrayBuffer())
    return arr[0] === 0x50 && arr[1] === 0x4b && arr[2] === 0x03 && arr[3] === 0x04
}

const makeNativeSource = url => ({ kind: 'native', url })
const makeFileSource = file => ({ kind: 'file', file })

const timeoutPromise = (ms, message) =>
    new Promise((_, reject) => {
        setTimeout(() => reject(new Error(message)), ms)
    })

const makeNativeSourceURLQuery = sourceURL =>
    `sourceURL=${encodeURIComponent(sourceURL)}`

const fetchNativeEntries = async sourceURL => {
    const response = await Promise.race([
        fetch(`ebook://ebook/entries?${makeNativeSourceURLQuery(sourceURL)}`, {
            headers: {
                'X-Ebook-Source-URL': sourceURL,
            },
        }),
        timeoutPromise(4000, 'native-entries-timeout'),
    ])
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.(
            `# EBOOKFETCH entries status=${response.status} ok=${response.ok} source=${sourceURL}`
        )
    } catch (_err) {}
    if (!response.ok) {
        throw new Error(`Failed to load native EPUB entries: ${response.status}`)
    }
    const payload = await response.json()
    try {
        const count = Array.isArray(payload?.entries) ? payload.entries.length : -1
        window.webkit?.messageHandlers?.print?.postMessage?.(
            `# EBOOKFETCH entries.json count=${count} source=${sourceURL}`
        )
    } catch (_err) {}
    return payload
}

const fetchNativeEntryResponse = async (sourceURL, subpath) => {
    const response = await Promise.race([
        fetch(`ebook://ebook/entry?subpath=${encodeURIComponent(subpath)}&${makeNativeSourceURLQuery(sourceURL)}`, {
            headers: {
                'X-Ebook-Source-URL': sourceURL,
            },
        }),
        timeoutPromise(4000, `native-entry-timeout:${subpath}`),
    ])
    try {
        window.webkit?.messageHandlers?.print?.postMessage?.(
            `# EBOOKFETCH entry status=${response.status} ok=${response.ok} subpath=${subpath} source=${sourceURL}`
        )
    } catch (_err) {}
    if (!response.ok) {
        return null
    }
    return response
}

const readNativeEntryText = async (response, name) => {
    if (!response) return null
    globalThis.manabiLoadEBookLastState = `native-loader-decoding-text:${name}`
    const arrayBuffer = await Promise.race([
        response.arrayBuffer(),
        timeoutPromise(4000, `native-entry-arraybuffer-timeout:${name}`),
    ])
    globalThis.manabiLoadEBookLastState = `native-loader-arraybuffer-ready:${name}`
    const charset = response.headers?.get?.('content-type')?.match(/charset=([^;]+)/i)?.[1]?.trim() || 'utf-8'
    let decoder
    try {
        decoder = new TextDecoder(charset)
    } catch (_err) {
        decoder = new TextDecoder('utf-8')
    }
    const text = decoder.decode(arrayBuffer)
    globalThis.manabiLoadEBookLastState = `native-loader-text-decoded:${name}`
    return text
}

const readNativeEntryBlob = async (response, name) => {
    if (!response) return null
    globalThis.manabiLoadEBookLastState = `native-loader-decoding-blob:${name}`
    const arrayBuffer = await Promise.race([
        response.arrayBuffer(),
        timeoutPromise(4000, `native-entry-arraybuffer-timeout:${name}`),
    ])
    globalThis.manabiLoadEBookLastState = `native-loader-arraybuffer-ready:${name}`
    const mimeType = response.headers?.get?.('content-type') || ''
    const blob = new Blob([arrayBuffer], mimeType ? { type: mimeType } : undefined)
    globalThis.manabiLoadEBookLastState = `native-loader-blob-decoded:${name}`
    return blob
}

const makeNativeEpubLoader = async (url, isCacheWarmer) => {
    logFix('nativeLoader:begin', {
        sourceURL: url,
        isCacheWarmer: !!isCacheWarmer,
    });
    const { entries: rawEntries = [] } = await fetchNativeEntries(url)
    logFix('nativeLoader:entries', {
        sourceURL: url,
        isCacheWarmer: !!isCacheWarmer,
        count: rawEntries.length,
    });
    const entries = rawEntries.map(entry => ({
        filename: entry.path,
        uncompressedSize: entry.size ?? 0,
    }))
    const sizeMap = new Map(entries.map(entry => [entry.filename, entry.uncompressedSize]))
    const entryNames = new Set(entries.map(entry => entry.filename))
    const replaceText = makeReplaceText(isCacheWarmer)

    return {
        entries,
        loadText: async name => {
            if (!entryNames.has(name)) {
                logFix('nativeLoader:missing-text-entry', {
                    sourceURL: url,
                    isCacheWarmer: !!isCacheWarmer,
                    name,
                });
                return null
            }
            globalThis.manabiLoadEBookLastState = `native-loader-awaiting-text:${name}`
            const response = await fetchNativeEntryResponse(url, name)
            globalThis.manabiLoadEBookLastState = `native-loader-text-ready:${name}`
            return readNativeEntryText(response, name)
        },
        loadBlob: async name => {
            if (!entryNames.has(name)) {
                logFix('nativeLoader:missing-blob-entry', {
                    sourceURL: url,
                    isCacheWarmer: !!isCacheWarmer,
                    name,
                });
                return null
            }
            globalThis.manabiLoadEBookLastState = `native-loader-awaiting-blob:${name}`
            const response = await fetchNativeEntryResponse(url, name)
            globalThis.manabiLoadEBookLastState = `native-loader-blob-ready:${name}`
            return readNativeEntryBlob(response, name)
        },
        getSize: name => sizeMap.get(name) ?? 0,
        replaceText,
        sourceURL: url,
    }
}

const makeZipLoader = async (file, isCacheWarmer) => {
    const {
        configure,
        ZipReader,
        BlobReader,
        TextWriter,
        BlobWriter
        } =
        await import('./vendor/zip.js')
    configure({
    useWebWorkers: false
    })
    const reader = new ZipReader(new BlobReader(file))
    const entries = await reader.getEntries()
    const map = new Map(entries.map(entry => [entry.filename, entry]))
    const load = f => (name, ...args) =>
    map.has(name) ? f(map.get(name), ...args) : null
    const loadText = load(entry => entry.getData(new TextWriter()))
    const loadBlob = load((entry, type) => entry.getData(new BlobWriter(type)))
    const getSize = name => map.get(name)?.uncompressedSize ?? 0
    //    const wrappedReplaceText = ((href, text, mediaType) => {
    //        replaceText(href, text, mediaType, isCacheWarmer)
    //    })
    const replaceText = makeReplaceText(isCacheWarmer)
    return {
        entries,
        loadText,
        loadBlob,
        getSize,
        replaceText
    }
}

const getFileEntries = async entry => entry.isFile ? entry :
    (await Promise.all(Array.from(
                        await new Promise((resolve, reject) => entry.createReader()
                                            .readEntries(entries => resolve(entries), error => reject(error))),
                        getFileEntries))).flat()

const nextAnimationFrame = () => new Promise(resolve => requestAnimationFrame(() => resolve()))

const waitForViewHostLayout = async (view, { timeoutMs = 2000, requireNonZeroSize = true } = {}) => {
    const startedAt = Date.now()
    while ((Date.now() - startedAt) < timeoutMs) {
        const rect = view?.getBoundingClientRect?.() ?? null
        const width = Number(rect?.width ?? 0)
        const height = Number(rect?.height ?? 0)
        const connected = !!view?.isConnected
        if (connected && (!requireNonZeroSize || (width > 0 && height > 0))) {
            return {
                ready: true,
                connected,
                width,
                height,
                waitedMs: Date.now() - startedAt,
            }
        }
        await nextAnimationFrame()
    }
    const finalRect = view?.getBoundingClientRect?.() ?? null
    return {
        ready: false,
        connected: !!view?.isConnected,
        width: Number(finalRect?.width ?? 0),
        height: Number(finalRect?.height ?? 0),
        waitedMs: Date.now() - startedAt,
    }
}

const isCBZ = ({
    name,
    type
}) =>
type === 'application/vnd.comicbook+zip' || name.endsWith('.cbz')

const isFB2 = ({
    name,
    type
}) =>
type === 'application/x-fictionbook+xml' || name.endsWith('.fb2')

const isFBZ = ({
    name,
    type
}) =>
type === 'application/x-zip-compressed-fb2' ||
name.endsWith('.fb2.zip') || name.endsWith('.fbz')

const setLoadStateForOwner = (owner, state) => {
    if (!owner || globalThis.reader === owner) {
        globalThis.manabiLoadEBookLastState = state;
    }
    return state;
};

const getView = async (source, isCacheWarmer, owner = null) => {
    let book
    if (source?.kind === 'native') {
        setLoadStateForOwner(owner, 'getView-native-source');
        logFix('getView:native-source', {
            sourceURL: source.url ?? null,
            isCacheWarmer: !!isCacheWarmer,
        });
        setLoadStateForOwner(owner, 'getView-native-importing-epub');
        const {
            EPUB
            } = await import('./epub.js')
        setLoadStateForOwner(owner, 'getView-native-awaiting-loader');
        const loader = await Promise.race([
            makeNativeEpubLoader(source.url, isCacheWarmer),
            new Promise((_, reject) => {
                setTimeout(() => reject(new Error('native-loader-timeout')), 15000)
            }),
        ])
        setLoadStateForOwner(owner, 'getView-native-loader-ready');
        setLoadStateForOwner(owner, 'getView-native-awaiting-book-init');
        book = await Promise.race([
            new EPUB(loader).init(),
            new Promise((_, reject) => {
                setTimeout(() => reject(new Error('native-book-init-timeout')), 15000)
            }),
        ])
        setLoadStateForOwner(owner, 'getView-native-book-ready');
        logFix('getView:native-book-ready', {
            sourceURL: source.url ?? null,
            isCacheWarmer: !!isCacheWarmer,
            bookDir: book?.dir ?? null,
            hasPageList: Array.isArray(book?.pageList) && book.pageList.length > 0,
        });
    } else if (source?.kind === 'file' && source.file?.size) {
        const file = source.file
        if (await isZip(file)) {
        const loader = await makeZipLoader(file, isCacheWarmer)
        if (isCBZ(file)) {
            throw new Error('File format not yet supported')
            //            const { makeComicBook } = await import('./comic-book.js')
            //            book = makeComicBook(loader, file)
        } else if (isFBZ(file)) {
            throw new Error('File format not yet supported')
            //            const { makeFB2 } = await import('./fb2.js')
            //            const { entries } = loader
            //            const entry = entries.find(entry => entry.filename.endsWith('.fb2'))
            //            const blob = await loader.loadBlob((entry ?? entries[0]).filename)
            //            book = await makeFB2(blob)
        } else {
            const {
                EPUB
                } = await import('./epub.js')
            book = await new EPUB(loader).init()
        }
        } else {
        throw new Error('File format not yet supported')
        //        const { isMOBI, MOBI } = await import('./mobi.js')
        //        if (await isMOBI(file)) {
        //            const fflate = await import('./vendor/fflate.js')
        //            book = await new MOBI({ unzlib: fflate.unzlibSync }).open(file)
        //        } else if (isFB2(file)) {
        //            const { makeFB2 } = await import('./fb2.js')
        //            book = await makeFB2(file)
        //        }
        }
    } else {
        throw new Error('File not found')
    }
    if (!book) throw new Error('File type not supported')
    setLoadStateForOwner(owner, 'getView-native-pre-create-view');
    const view = document.createElement('foliate-view')
    setLoadStateForOwner(owner, 'getView-native-view-created');
    logFix('getView:view-created', {
        isCacheWarmer: !!isCacheWarmer,
        tagName: view?.tagName ?? null,
    });
    view.dataset.isCache = isCacheWarmer;
    const readerStage = document.getElementById('reader-stage');
    setLoadStateForOwner(owner, 'getView-native-pre-append-view');
    (isCacheWarmer ? document.body : (readerStage || document.body)).append(view);
    setLoadStateForOwner(owner, 'getView-native-view-appended');
    logFix('getView:view-appended', {
        isCacheWarmer: !!isCacheWarmer,
        parentTag: view.parentElement?.tagName ?? null,
        hasShadowRoot: !!view.shadowRoot,
    });
    forwardShadowErrors(view.shadowRoot);
    if (isCacheWarmer) {
        view.style.display = 'none'
        view.style.contain = 'strict'
        view.style.position = 'absolute'
        view.style.left = '-9001px'
        view.style.width = 0
        view.style.height = 0
        view.style.pointerEvents = 'none'
    }
    await customElements.whenDefined('foliate-view')
    setLoadStateForOwner(owner, 'getView-native-awaiting-layout');
    const layoutState = isCacheWarmer
        ? await waitForViewHostLayout(view, { timeoutMs: 500, requireNonZeroSize: false })
        : await waitForViewHostLayout(view, { timeoutMs: 2500, requireNonZeroSize: true })
    logFix('getView:view-layout-ready', {
        isCacheWarmer: !!isCacheWarmer,
        ready: layoutState.ready,
        connected: layoutState.connected,
        width: layoutState.width,
        height: layoutState.height,
        waitedMs: layoutState.waitedMs,
        parentTag: view.parentElement?.tagName ?? null,
        parentWidth: Number(view.parentElement?.getBoundingClientRect?.()?.width ?? 0),
        parentHeight: Number(view.parentElement?.getBoundingClientRect?.()?.height ?? 0),
    });
    setLoadStateForOwner(owner, 'getView-native-pre-open-view');
    logFix('getView:view-open-begin', {
        isCacheWarmer: !!isCacheWarmer,
        bookDir: book?.dir ?? null,
    });
    try {
        await Promise.race([
            Promise.resolve(view.open(book, isCacheWarmer)),
            new Promise((_, reject) => {
                setTimeout(() => reject(new Error('view-open-timeout')), 5000)
            }),
        ])
    } catch (error) {
        logFix('getView:view-open-error', {
            isCacheWarmer: !!isCacheWarmer,
            message: error?.message ?? String(error),
            hasRenderer: !!view?.renderer,
            hasDocument: !!view?.document,
        });
        try { view.close?.() } catch (_error) {}
        try { view.remove?.() } catch (_error) {}
        throw error
    }
    logFix('getView:view-open-resolved', {
        isCacheWarmer: !!isCacheWarmer,
        hasRenderer: !!view?.renderer,
        hasDocument: !!view?.document,
        currentIndex: Number.isFinite(view?.renderer?.currentIndex) ? view.renderer.currentIndex : null,
    });

    // Hide scrollbars on the scrolling container inside foliate-paginator's shadow DOM
    const paginator = view.shadowRoot?.querySelector('foliate-paginator');
    if (paginator?.shadowRoot) {
        const style = document.createElement('style');
        style.textContent = `
        #container {
        scrollbar-width: none !important;         /* Firefox */
        -ms-overflow-style: none !important;      /* IE/Edge */
        }
        #container::-webkit-scrollbar {
        display: none !important;                 /* WebKit (macOS/iOS) */
        width: 0 !important;
        height: 0 !important;
        }
        `;
        paginator.shadowRoot.appendChild(style);

        const sideNavWidth = 32;
        document.documentElement.style.setProperty('--side-nav-width', `${sideNavWidth}px`);
        // Also set --side-nav-width on the inner view, so it propagates into the iframe's shadow DOM.
        const syncSideNavWidth = () => {
        const width = getComputedStyle(document.body)
        .getPropertyValue('--side-nav-width').trim();
        if (view) {
        view.style.setProperty('--side-nav-width', width);
        // Also update the renderer's CSS variable, if setSideNavWidth exists
        if (view.renderer && typeof view.renderer.setSideNavWidth === "function") {
        view.renderer.setSideNavWidth(width);
        }
        }
        };
        window.addEventListener('resize', syncSideNavWidth);
        syncSideNavWidth();
    }

    return view
}

const getCSSForBookContent = ({
    spacing,
    justify,
    hyphenate
    }) => `
@namespace epub "http://www.idpf.org/2007/ops";
html {
color-scheme: light dark;
cursor: inherit;
}
/* https://github.com/whatwg/html/issues/5426 */
@media (prefers-color-scheme: dark) {
a:link {
color: lightblue;
}
}
p, li, blockquote, dd {
line-height: ${spacing};
text-align: ${justify ? 'justify' : 'start'};
-webkit-hyphens: ${hyphenate ? 'auto' : 'manual'};
hyphens: ${hyphenate ? 'auto' : 'manual'};
-webkit-hyphenate-limit-before: 3;
-webkit-hyphenate-limit-after: 2;
-webkit-hyphenate-limit-lines: 2;
hanging-punctuation: allow-end last;
widows: 2;
}
/* prevent the above from overriding the align attribute */
[align="left"] { text-align: left; }
[align="right"] { text-align: right; }
[align="center"] { text-align: center; }
[align="justify"] { text-align: justify; }

pre {
white-space: pre-wrap !important;
}
aside[epub|type~="endnote"],
aside[epub|type~="footnote"],
aside[epub|type~="note"],
aside[epub|type~="rearnote"] {
display: none;
}

.manabi-tracking-section {
/*contain: initial !important;*/
contain: style layout !important;
}

body *:not([class^="manabi-"]):not(manabi-segment, manabi-segment *):not(manabi-container):not(manabi-sentence, manabi-sentence *):not(#manabi-tracking-section-subscription-preview-inline-notice) {
    font-family: inherit !important;
    font-weight: inherit !important;
    background: inherit !important;
    color: inherit !important;
    /* prevent height: 100% type values from breaking getBoundingClientRect layout in paginator */
    height: inherit !important;
}
body.reader-is-single-media-element-without-text *:not(.manabi-tracking-container *):not(manabi-segment *) {
max-height: 99vh;
}
/*
 reader-sentinel {
 position: relative;
 display: inline; /*-block;*/
 width: 4px !important;
 height: 4px !important;
 opacity: 1 !important;
 pointer-events: none !important;
 contain: strict;
 background: red !important;
 }
 */
reader-sentinel {
position: relative !important;
display: inline-block !important;
width: 0 !important;
height: 0 !important;
padding: 0 !important;
contain: strict !important;
pointer-events: none !important;
opacity: 0 !important;
vertical-align: bottom !important;
break-before: avoid !important;
break-after: avoid !important;
break-inside: avoid !important;
}
`

const $ = document.querySelector.bind(document)

const locales = 'en'
const percentFormat = new Intl.NumberFormat(locales, {
style: 'percent'
})

class SideNavChevronAnimator {
    #icons = {
        l: null,
        r: null,
    };
    #hideTimers = {
        l: null,
        r: null,
    };

    constructor() {
        this.#icons = {
            l: document.querySelector('#btn-scroll-left .icon'),
            r: document.querySelector('#btn-scroll-right .icon'),
        };
    }

    #normalizeKey(key) {
        if (key === 'l' || key === 'left') return 'l';
        if (key === 'r' || key === 'right') return 'r';
        return null;
    }

    isHolding(key) {
        const k = this.#normalizeKey(key);
        if (!k) return false;
        return !!this.#hideTimers[k];
    }

    set({ leftOpacity = null, rightOpacity = null, holdMs = 0, fadeMs = 200 } = {}) {
        this.#apply('l', leftOpacity, holdMs, fadeMs);
        this.#apply('r', rightOpacity, holdMs, fadeMs);
    }

    flash(direction, { holdMs = 280, fadeMs = 200 } = {}) {
        const isLeft = direction === 'left';
        this.set({
            leftOpacity: isLeft ? 1 : 0,
            rightOpacity: isLeft ? 0 : 1,
            holdMs,
            fadeMs,
        });
    }

    reset() {
        ['l', 'r'].forEach(key => this.#fadeIcon(key, 0));
    }

    #apply(key, value, holdMs, fadeMs) {
        if (value == null) return;
        const icon = this.#icons[key];
        if (!icon) return;

        clearTimeout(this.#hideTimers[key]);
        this.#hideTimers[key] = null;

        const numeric = Number(value);
        const shouldHide = value === '' || (!Number.isNaN(numeric) && numeric <= 0);
        if (shouldHide) {
            this.#fadeIcon(key, fadeMs);
            return;
        }

        const targetOpacity = Number.isNaN(numeric) ? 0 : Math.min(1, numeric);
        icon.style.transitionDuration = `${fadeMs}ms`;
        if (targetOpacity >= 1) {
            icon.classList.add('chevron-visible');
            icon.style.removeProperty('opacity');
        } else {
            icon.classList.remove('chevron-visible');
            icon.style.opacity = targetOpacity;
        }

        if (holdMs > 0) {
            this.#hideTimers[key] = setTimeout(() => this.#fadeIcon(key, fadeMs), holdMs);
        }
    }

    #fadeIcon(key, fadeMs = 200) {
        const icon = this.#icons[key];
        if (!icon) return;
        clearTimeout(this.#hideTimers[key]);
        this.#hideTimers[key] = null;
        icon.style.transitionDuration = `${fadeMs}ms`;
        icon.classList.remove('chevron-visible');
        icon.style.opacity = '0';
    }
}

class Reader {
    #allowForwardNavHide = false;
    #logScrubDiagnostic(_event, _payload = {}) {}
    #logChevronDiagnostic(_event, _payload = {}) {}
    #loadingTimeoutId = null;
    #show(btn, show = true) {
        if (show) {
            btn.hidden = false;
            btn.style.visibility = 'visible';
            btn.style.display = '';
        } else {
            btn.hidden = true;
            btn.style.visibility = 'hidden';
            btn.style.display = 'none';
        }
    }
    setLoadingIndicator(visible) {
        logBug('loading-indicator:set', {
            visible: !!visible,
            bodyHasLoading: document?.body?.classList?.contains?.('loading') ?? null,
        });
        const indicator = document.getElementById('loading-indicator');
        if (indicator) indicator.classList.toggle('show', !!visible);
        // Keep nav/chevrons interactive by avoiding body-level loading class.
    }
    #tocView
    #chevronAnimator = null;
    #progressSlider = null
    #tickContainer = null
    #progressScrubState = null
    #handleProgressSliderPointerDown = (event) => {
    if (!this.#progressSlider) return;
    if (event.pointerType === 'mouse' && event.button !== 0) return;
    if (this.#progressScrubState) {
    this.#finalizeProgressScrubSession({ cancel: true });
    }
    const originDescriptor = this.navHUD?.getCurrentDescriptor();
    const originFraction = originDescriptor?.fraction ?? Number(this.#progressSlider?.value ?? NaN);
    this.#progressSlider.setPointerCapture?.(event.pointerId);
    this.#progressScrubState = {
    pointerId: event.pointerId,
    pendingEnd: false,
    cancelRequested: false,
    timeoutId: null,
    releaseFraction: null,
    originDescriptor,
    originFraction: Number.isFinite(originFraction) ? originFraction : null,
    };
    this.navHUD?.beginProgressScrubSession(originDescriptor);
    this.#logScrubDiagnostic('pointer-down', {
    pointerId: event.pointerId,
    pointerType: event.pointerType,
    sliderValue: Number(this.#progressSlider?.value ?? NaN),
    });
    }
    #handleProgressSliderPointerUp = (event) => {
    if (!this.#progressScrubState || this.#progressScrubState.pointerId !== event.pointerId) return;
    this.#progressScrubState.releaseFraction = Number(this.#progressSlider?.value ?? NaN);
    this.#progressSlider?.releasePointerCapture?.(event.pointerId);
    this.#logScrubDiagnostic('pointer-up', {
    pointerId: event.pointerId,
    sliderValue: Number(this.#progressSlider?.value ?? NaN),
    });
    this.#requestProgressScrubEnd(false);
    }
    #handleProgressSliderPointerCancel = (event) => {
    if (!this.#progressScrubState || this.#progressScrubState.pointerId !== event.pointerId) return;
    this.#progressScrubState.releaseFraction = Number(this.#progressSlider?.value ?? NaN);
    this.#progressSlider?.releasePointerCapture?.(event.pointerId);
    this.#logScrubDiagnostic('pointer-cancel', {
    pointerId: event.pointerId,
    sliderValue: Number(this.#progressSlider?.value ?? NaN),
    });
    this.#requestProgressScrubEnd(true);
    }
    hasLoadedLastPosition = false
    markedAsFinished = false;
    lastPercentValue = null;
    lastPageEstimate = null;
    lastKnownFraction = 0;
    jumpUnit = 'percent';
    #jumpInput = null;
    #jumpButton = null;
    #jumpUnitSelect = null;
    style = {
        spacing: 1.4,
        justify: true,
        hyphenate: true,
    }
    annotations = new Map()
    annotationsByValue = new Map()
    openSideBar() {
    $('#dimming-overlay').classList.add('show')
    $('#side-bar').classList.add('show')
    if (this.#tocView?.setCurrentHref && this.view?.renderer?.tocItem?.href) {
    this.#tocView.setCurrentHref(this.view.renderer.tocItem.href)
    }
    }
    closeSideBar() {
    $('#dimming-overlay').classList.remove('show')
    $('#side-bar').classList.remove('show')
    }
    toggleTableOfContents() {
    const sideBar = document.getElementById('side-bar');
    if (!sideBar) return;
    if (sideBar.classList.contains('show')) {
    this.closeSideBar();
    } else {
    this.openSideBar();
    }
    }
    setHideNavigationDueToScroll(shouldHide, source = 'unknown') {
        const allowSource = new Set([
            'scroll-toggle',
            'nav-visibility',
            'relocate',
            'relocate-force',
            'swipe-left',
            'swipe-right',
            'keyboard',
            'arrow',
            'side-nav',
            'tap',
            'unknown',
        ]).has(source);
        const canHide = !shouldHide || this.#allowForwardNavHide || allowSource;
        if (!canHide) {
            logNavHide('reader:set-hide-blocked', {
                requested: !!shouldHide,
                source,
                allowForwardNavHide: this.#allowForwardNavHide,
                navHiddenClass: document?.body?.classList?.contains?.('nav-hidden') ?? null,
            });
            logBug('nav-hide-blocked', { reason: 'gate', requestedHide: shouldHide, source });
            return;
        }
        if (shouldHide && this.#allowForwardNavHide) {
            this.#allowForwardNavHide = false; // consume gate
        }
        if (!shouldHide) {
            // Showing again resets the gate so a future hide is allowed.
            this.#allowForwardNavHide = true;
            logNavHide('reader:reset-hide-gate', {
                source,
                navHiddenClass: document?.body?.classList?.contains?.('nav-hidden') ?? null,
            });
        }
        logNavHide('reader:set-hide', {
            requested: !!shouldHide,
            applied: !!shouldHide,
            source,
            gateConsumed: shouldHide ? !this.#allowForwardNavHide : null,
            navHiddenClass: document?.body?.classList?.contains?.('nav-hidden') ?? null,
        });
        logBug('nav-hide-apply', { shouldHide, source, gateConsumed: !this.#allowForwardNavHide });
        this.navHUD?.setHideNavigationDueToScroll(shouldHide, source, this._lastRelocateContext ?? null);
        updateNavHiddenClass(shouldHide);
    }

    setNavHiddenState(shouldHide) {
    this.navHUD?.setNavHiddenState?.(shouldHide);
    }
    constructor() {
    this.navHUD = new NavigationHUD({
    formatPercent: value => percentFormat.format(value),
    getRenderer: () => this.view?.renderer,
    onJumpRequest: descriptor => this.#goToDescriptor(descriptor),
    });
    this.allowForwardNavHide = () => { this.#allowForwardNavHide = true; };
    this.#chevronAnimator = new SideNavChevronAnimator();
    this._lastRelocateSectionIndex = null;
    $('#side-bar-close-button').addEventListener('click', () => {
    this.closeSideBar()
    })
    $('#dimming-overlay').addEventListener('click', () => this.closeSideBar())
    }
    async open(source) {
    logFix('reader.open:begin', {
    hasSource: !!source,
    pageURL: window.location.href,
    });
    setLoadStateForOwner(this, 'reader-open-begin');
    this.setLoadingIndicator(true);
    this.hasLoadedLastPosition = false
    this.source = source
    setLoadStateForOwner(this, 'reader-open-awaiting-view');
    this.view = await getView(source, false, this)
    setLoadStateForOwner(this, 'reader-open-view-ready');
    logFix('reader.open:view-ready', {
    hasView: !!this.view,
    hasRenderer: !!this.view?.renderer,
    tagName: this.view?.tagName ?? null,
    });
    // this.view.renderer.setAttribute('animated', true) // Flows top to bottom instead of like a book...
    if (typeof window.initialLayoutMode !== 'undefined') {
    this.view.renderer.setAttribute('flow', window.initialLayoutMode)
    logFix('reader.open:flow-set', {
    layoutMode: window.initialLayoutMode ?? null,
    });
    }
    this.view.renderer.addEventListener('goTo', this.#onGoTo.bind(this))
    this.view.renderer.addEventListener('didDisplay', this.#onDidDisplay.bind(this))
    this.view.renderer.addEventListener('relocate', this.#onRendererRelocate.bind(this))
    this.view.addEventListener('load', this.#onLoad.bind(this))
    this.view.addEventListener('relocate', this.#onRelocate.bind(this))
    this._sideNavCooldownUntil = 0;

    const {
    book
    } = this.view
    this.bookDir = book.dir || 'ltr';
    this.isRTL = this.bookDir === 'rtl';
    try {
    const line = `# EBOOKCHEVRON_VIEW bookDir=${this.bookDir} isRTL=${this.isRTL}`;
    window.webkit?.messageHandlers?.print?.postMessage?.(line);
    console.log(line);
    } catch (_err) {
    // best-effort diagnostics
    }
    document.body.dir = this.bookDir;
    this.navHUD?.setIsRTL(this.isRTL);
    this.navHUD?.setPageTargets(book.pageList ?? []);
    this.view.renderer.setStyles?.(getCSSForBookContent(this.style))
    setLoadStateForOwner(this, 'reader-open-configured');
    logFix('reader.open:configured', {
    bookDir: this.bookDir ?? null,
    isRTL: !!this.isRTL,
    hasPageList: Array.isArray(book.pageList) && book.pageList.length > 0,
    });
    //        this.view.renderer.next()

    $('#nav-bar').style.visibility = 'visible'
    this.buttons = {
    prev: document.getElementById('btn-prev-chapter'),
    next: document.getElementById('btn-next-chapter'),
    finish: document.getElementById('btn-finish'),
    restart: document.getElementById('btn-restart'),
    };
    // Hide all other nav buttons except spinners
    for (const btn of Object.values(this.buttons)) {
    btn && (btn.hidden = true);
    }

    // Flip chevron icons for RTL books
    if (this.isRTL) {
    const flipChevron = (btn, leftArrow) => {
    const path = btn.querySelector('path');
    if (path) {
    path.setAttribute('d', leftArrow ?
    'M 15 6 L 9 12 L 15 18' // left chevron (◀)
    :
    'M 9 6 L 15 12 L 9 18'); // right chevron (▶)
    }
    };

    flipChevron(this.buttons.prev, false); // ▶
    flipChevron(this.buttons.next, true); // ◀

    // Swap label/icon order for chapter buttons in RTL
    // Ensure "Next Chapter" shows "< Next Chapter"
    const nextBtn = this.buttons.next;
    const nextLabel = nextBtn.querySelector('.button-label');
    const nextIcon = nextBtn.querySelector('svg');
    if (nextIcon && nextLabel && nextIcon !== nextLabel.previousSibling) {
    nextBtn.insertBefore(nextIcon, nextLabel);
    }

    // Ensure "Previous Chapter" shows "Previous Chapter >"
    const prevBtn = this.buttons.prev;
    const prevLabel = prevBtn.querySelector('.button-label');
    const prevIcon = prevBtn.querySelector('svg');
    if (prevIcon && prevLabel && prevLabel !== prevIcon.previousSibling) {
    prevBtn.insertBefore(prevLabel, prevIcon);
    }

    // Spinner placement logic for RTL
    // For prev: spinner after label (right side, where chevron is)
    // For next: spinner before label (left side, where chevron is)
    if (this.buttons.prev) {
    this.buttons.prev._spinnerAfterLabel = true;
    }
    if (this.buttons.next) {
    this.buttons.next._spinnerAfterLabel = false;
    }
    } else {
    // LTR: spinner replaces icon (before label for prev, after label for next)
    if (this.buttons.prev) {
    this.buttons.prev._spinnerAfterLabel = false;
    }
    if (this.buttons.next) {
    this.buttons.next._spinnerAfterLabel = false;
    }
    }
    Object.values(this.buttons).forEach(btn =>
    btn.addEventListener('click', this.#onNavButtonClick.bind(this))
    );
    // Side-nav scroll handlers
    const leftSideBtn = document.getElementById('btn-scroll-left');
    if (leftSideBtn) {
    const triggerNavLeft = async () => {
        const now = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
        if (now < this._sideNavCooldownUntil) return;
        this._sideNavCooldownUntil = now + 180; // debounce rapid double-fires
        await this.view.goLeft();
    };
    leftSideBtn.addEventListener('click', async () => {
        logBug('side-nav:click', { direction: 'left' });
        logNavHide('side-nav:click', {
            direction: 'left',
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
            bodyNavHidden: document?.body?.classList?.contains?.('nav-hidden') ?? null,
        });
        await triggerNavLeft();
    });
    leftSideBtn.addEventListener('pointerdown', async (e) => {
        logBug('side-nav:pointerdown', { direction: 'left' });
        logNavHide('side-nav:pointerdown', {
            direction: 'left',
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
            bodyNavHidden: document?.body?.classList?.contains?.('nav-hidden') ?? null,
        });
        e.preventDefault();
        await triggerNavLeft();
    });
    leftSideBtn.addEventListener('pointerup', async () => {
        logBug('side-nav:pointerup', { direction: 'left' });
        logNavHide('side-nav:pointerup', {
            direction: 'left',
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
            bodyNavHidden: document?.body?.classList?.contains?.('nav-hidden') ?? null,
        });
        await triggerNavLeft();
    });
    }
    const rightSideBtn = document.getElementById('btn-scroll-right');
    if (rightSideBtn) {
    const triggerNavRight = async () => {
        const now = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
        if (now < this._sideNavCooldownUntil) return;
        this._sideNavCooldownUntil = now + 180;
        await this.view.goRight();
    };
    rightSideBtn.addEventListener('click', async () => {
        logBug('side-nav:click', { direction: 'right' });
        logNavHide('side-nav:click', {
            direction: 'right',
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
            bodyNavHidden: document?.body?.classList?.contains?.('nav-hidden') ?? null,
        });
        await triggerNavRight();
    });
    rightSideBtn.addEventListener('pointerdown', async (e) => {
        logBug('side-nav:pointerdown', { direction: 'right' });
        logNavHide('side-nav:pointerdown', {
            direction: 'right',
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
            bodyNavHidden: document?.body?.classList?.contains?.('nav-hidden') ?? null,
        });
        e.preventDefault();
        await triggerNavRight();
    });
    rightSideBtn.addEventListener('pointerup', async () => {
        logBug('side-nav:pointerup', { direction: 'right' });
        logNavHide('side-nav:pointerup', {
            direction: 'right',
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
            bodyNavHidden: document?.body?.classList?.contains?.('nav-hidden') ?? null,
        });
        await triggerNavRight();
    });
    }

    const flashSideNav = (direction) => {
    this.view?.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
    detail: {
    leftOpacity: direction === 'left' ? 1 : 0,
    rightOpacity: direction === 'right' ? 1 : 0,
    holdMs: 180,
    fadeMs: 180,
    source: 'button:pointer',
    }
    }));
    };
    leftSideBtn?.addEventListener('pointerdown', () => flashSideNav('left'));
    rightSideBtn?.addEventListener('pointerdown', () => flashSideNav('right'));

    // Immediate tap feedback for side-nav chevrons on iOS/touch
    document.querySelectorAll('.side-nav').forEach(nav => {
    nav.addEventListener('touchstart', () => {
    nav.classList.add('pressed');
    }, {
    passive: true
    });
    nav.addEventListener('touchend', () => {
    nav.classList.remove('pressed');
    });
    nav.addEventListener('touchcancel', () => {
    nav.classList.remove('pressed');
    });
        });

        // Side-nav opacity wiring
        this.view.addEventListener('sideNavChevronOpacity', e => {
            const detail = e?.detail ?? {};
            const holdMs = typeof detail.holdMs === 'number' ? detail.holdMs : 0;
            const fadeMs = typeof detail.fadeMs === 'number' ? detail.fadeMs : 200;
            this.#chevronAnimator?.set({
                leftOpacity: detail.leftOpacity,
                rightOpacity: detail.rightOpacity,
                holdMs,
                fadeMs,
            });
            this.#logChevronDiagnostic('chevron:event', {
                source: detail?.source ?? null,
                holdMs,
                fadeMs,
                left: detail.leftOpacity ?? null,
                right: detail.rightOpacity ?? null,
            });
        });
    // Listen for resetSideNavChevrons custom event to reset chevrons
    document.addEventListener('resetSideNavChevrons', () => this.#resetSideNavChevrons());

    // Legacy layout support: reorder toolbar children only if the old stacks exist
    const navBar = document.getElementById('nav-bar');
    const leftStack = document.getElementById('left-stack');
    const rightStack = document.getElementById('right-stack');
    const progressWrapper = document.getElementById('progress-wrapper');
    if (navBar && leftStack && rightStack && progressWrapper) {
    navBar.innerHTML = '';
    if (this.isRTL) {
    navBar.append(rightStack, progressWrapper, leftStack);
    } else {
    navBar.append(leftStack, progressWrapper, rightStack);
    }
    }

    const slider = $('#progress-slider')
    this.#progressSlider = slider
    this.#tickContainer = document.getElementById('progress-ticks')
    slider.dir = book.dir
    const goToFractionImmediate = e => {
        this.view.goToFraction(parseFloat(e.target.value))
    };
    slider.addEventListener('input', goToFractionImmediate)
    slider.addEventListener('pointerdown', this.#handleProgressSliderPointerDown)
    slider.addEventListener('pointerup', this.#handleProgressSliderPointerUp)
    slider.addEventListener('pointercancel', this.#handleProgressSliderPointerCancel)

    this.book = book;
    // Cache-warmer section page counts are disabled; rely on live renderer counts instead.
    const initialCounts = null;

    slider.style.setProperty('--value', slider.value);
    slider.style.setProperty('--min', slider.min == '' ? '0' : slider.min);
    slider.style.setProperty('--max', slider.max == '' ? '100' : slider.max);
    slider.addEventListener('input', () => slider.style.setProperty('--value', slider.value));

    const tickFractions = this.#computeSectionTicks(initialCounts);
    this.#renderSectionTicks(initialCounts, tickFractions);

    // Percent jump input/button wiring
    const percentInput = document.getElementById('percent-jump-input');
    const percentButton = document.getElementById('percent-jump-button');
    const jumpUnitSelect = document.getElementById('jump-unit-select');
    this.#jumpInput = percentInput;
    this.#jumpButton = percentButton;
    this.#jumpUnitSelect = jumpUnitSelect;
    this.jumpUnit = 'percent';
    this.lastPageEstimate = null;
    this.#updateJumpUnitAvailability();
    this.#syncJumpInputWithState();

    const handleJumpInputChange = () => {
    const value = parseFloat(percentInput.value);
    percentButton.disabled = !this.#isJumpInputValueValid(value);
    };
    percentInput.addEventListener('input', handleJumpInputChange);

    jumpUnitSelect?.addEventListener('change', () => {
    this.jumpUnit = 'percent';
    this.#syncJumpInputWithState();
    percentButton.disabled = true;
    });

    percentButton.addEventListener('click', () => {
    const value = parseFloat(percentInput.value);
    if (!this.#isJumpInputValueValid(value)) return;
    this.lastPercentValue = value;
    this.lastKnownFraction = value / 100;
    percentButton.disabled = true;
    this.view.goToFraction(value / 100);
    this.closeSideBar();
    });

    document.addEventListener('keydown', this.#handleKeydown.bind(this))

    const processTouchStart = function(event) {
    // Ignore touches inside foliate-js viewer iframe
    if (event.target && event.target.ownerDocument !== document) return

    window.webkit?.messageHandlers?.touchstartCallbackHandler?.postMessage?.({
    touchedEntryWithElementId: null,
    wasAlreadySelected: false,
    })
    }
    document.addEventListener('touchstart', processTouchStart, {
    passive: true
    })
    document.addEventListener('mousedown', processTouchStart, {
    passive: true
    })


    const title = book.metadata?.title ?? 'Untitled Book'
    document.title = title
    $('#side-bar-title').innerText = title
    const author = book.metadata?.author
    let authorText = typeof author === 'string' ? author :
    author
    ?.map(author => typeof author === 'string' ? author : author.name)
    ?.join(', ') ??
    ''
    $('#side-bar-author').innerText = authorText
    window.webkit.messageHandlers.pageMetadataUpdated.postMessage({
    'title': title,
    'author': authorText,
    'url': window.top.location.href
    })

    Promise.resolve(book.getCover?.())?.then(blob => {
    blob ? $('#side-bar-cover').src = URL.createObjectURL(blob) : null
    })

    const toc = book.toc
    if (toc) {
    this.#tocView = createTOCView(toc, async (href) => {
    await this.view.goTo(href).catch(e => console.error(e))
    this.closeSideBar()
    })
    $('#toc-view').append(this.#tocView.element)
    }

    // load and show highlights embedded in the file by Calibre
    setLoadStateForOwner(this, 'reader-open-awaiting-calibre-bookmarks');
    const bookmarks = await book.getCalibreBookmarks?.()
    setLoadStateForOwner(this, 'reader-open-calibre-bookmarks-ready');
    if (Array.isArray(bookmarks) && bookmarks.length > 0) {
    try {
    setLoadStateForOwner(this, 'reader-open-awaiting-epubcfi-import');
    const {
    fromCalibreHighlight
    } = await Promise.race([
    import('./epubcfi.js'),
    new Promise((_, reject) => {
    setTimeout(() => reject(new Error('epubcfi-import-timeout')), 3000)
    }),
    ])
    setLoadStateForOwner(this, 'reader-open-epubcfi-import-ready');
    for (const obj of bookmarks) {
    if (obj.type === 'highlight') {
    const value = fromCalibreHighlight(obj)
    const color = obj.style.which
    const note = obj.notes
    const annotation = {
    value,
    color,
    note
    }
    const list = this.annotations.get(obj.spine_index)
    if (list) list.push(annotation)
    else this.annotations.set(obj.spine_index, [annotation])
    this.annotationsByValue.set(value, annotation)
    }
    }
    } catch (error) {
    setLoadStateForOwner(this, `reader-open-calibre-bookmarks-skip:${sanitizeErrorValue(error?.message ?? error)}`);
    logFix('reader.open:calibre-bookmarks-skip', {
    message: error?.message ?? String(error),
    bookmarkCount: bookmarks.length,
    });
    }
    }
    setLoadStateForOwner(this, 'reader-open-complete');
    if (!this.hasLoadedLastPosition && this.view?.renderer?.firstSection) {
    try {
    setLoadStateForOwner(this, 'reader-open-awaiting-initial-first-section');
    await Promise.race([
    this.view.renderer.firstSection(),
    new Promise((_, reject) => {
    setTimeout(() => reject(new Error('initial-first-section-timeout')), 12000)
    }),
    ])
    setLoadStateForOwner(this, 'reader-open-initial-first-section-ready');
    } catch (error) {
    setLoadStateForOwner(this, `reader-open-initial-first-section-error:${sanitizeErrorValue(error?.message ?? error)}`);
    logFix('reader.open:initial-first-section-error', {
    message: error?.message ?? String(error),
    });
    }
    }
    }

    async updateNavButtons() {
    // Remove any nav-spinner left over from finish/restart click
    document.querySelectorAll('.ispinner.nav-spinner').forEach(spinner => {
    const btn = spinner.closest('button');
    if (btn && btn._originalIcon) {
    spinner.replaceWith(btn._originalIcon);
    delete btn._originalIcon;
    }
    const label = btn.querySelector('.button-label');
    if (label) label.style.visibility = '';
    });
    if (!this.view?.renderer) return;
    const r = this.view.renderer;
    // Use new section start/end helpers if available
    const atSectionStart = typeof r.isAtSectionStart === "function" ? await r.isAtSectionStart() : false;
    const atSectionEnd = typeof r.isAtSectionEnd === "function" ? await r.isAtSectionEnd() : false;
    // Use public helpers to detect prev/next section
    const hasPrevSection = typeof r.getHasPrevSection === "function" ? await r.getHasPrevSection() : true;
    const hasNextSection = typeof r.getHasNextSection === "function" ? await r.getHasNextSection() : true;
    const shouldShowPrev = atSectionStart && hasPrevSection;
    const shouldShowNext = atSectionEnd && hasNextSection;

    this.#show(this.buttons.prev, shouldShowPrev);

    if (shouldShowNext) {
    this.#show(this.buttons.next, true);
    this.#show(this.buttons.finish, false);
    this.#show(this.buttons.restart, false);
    } else if (atSectionEnd && !hasNextSection) {
    this.#show(this.buttons.next, false);
    if (this.markedAsFinished) {
    this.#show(this.buttons.restart, true);
    this.#show(this.buttons.finish, false);
    } else {
    this.#show(this.buttons.finish, true);
    this.#show(this.buttons.restart, false);
    }
    } else {
    this.#show(this.buttons.next, false);
    this.#show(this.buttons.finish, false);
    this.#show(this.buttons.restart, false);
    }
    this.#setForwardChevronHint(shouldShowNext);

    // RTL/LTR logic for disabling/hiding side chevrons
    const btnScrollLeft = document.getElementById('btn-scroll-left');
    const btnScrollRight = document.getElementById('btn-scroll-right');
    if (btnScrollLeft && btnScrollRight) {
    if (this.isRTL) {
    // In RTL, left chevron = go forward, right chevron = go backward
    // Disable left at end, right at start
    btnScrollLeft.disabled = (atSectionEnd && !hasNextSection);
    btnScrollRight.disabled = (atSectionStart && !hasPrevSection);
    } else {
    // LTR, left chevron = backward, right chevron = forward
    // Disable left at start, right at end
    btnScrollLeft.disabled = (atSectionStart && !hasPrevSection);
    btnScrollRight.disabled = (atSectionEnd && !hasNextSection);
    }
    }

    // Consolidate restart icon SVG path update
    const restartBtn = this.buttons.restart;
    if (restartBtn) {
    const iconPath = restartBtn.querySelector('svg path');
    if (iconPath) {
    iconPath.setAttribute('d', 'M13 3a9 9 0 1 0 9 9h-2a7 7 0 1 1-7-7v3l4-4-4-4v3z');
    iconPath.setAttribute('fill', 'currentColor');
    iconPath.setAttribute('stroke', 'none');
    }
    }
    this.navHUD?.setNavContext({
    atSectionStart,
    atSectionEnd,
    hasPrevSection,
    hasNextSection,
    showingFinish: this.#isButtonVisible(this.buttons.finish),
    showingRestart: this.#isButtonVisible(this.buttons.restart),
    });
    }

    #isButtonVisible(button) {
    if (!button) return false;
    return !button.hidden && button.style.display !== 'none';
    }
    #setForwardChevronHint(shouldShow) {
        const forwardBtn = document.getElementById(this.isRTL ? 'btn-scroll-left' : 'btn-scroll-right');
        if (!forwardBtn) return;
        forwardBtn.classList.toggle('show-next', !!shouldShow);
        const icon = forwardBtn.querySelector('.icon');
        if (!icon) return;
        const isHovered = typeof forwardBtn.matches === 'function' ? forwardBtn.matches(':hover') : false;
        const isHeld = this.#chevronAnimator?.isHolding(forwardBtn.id === 'btn-scroll-left' ? 'l' : 'r') ?? false;
        this.#logChevronDiagnostic('chevron:forwardHint', {
        shouldShow,
        isHovered,
        isHeld,
        isPressed: forwardBtn.classList.contains('pressed'),
        iconVisible: icon.classList.contains('chevron-visible'),
        inlineOpacity: icon.style.opacity || null,
        });
        if (shouldShow) {
        icon.classList.add('chevron-visible');
        icon.style.opacity = '1';
        } else if (!forwardBtn.classList.contains('pressed') && !isHovered && !isHeld) {
        icon.classList.remove('chevron-visible');
        icon.style.opacity = '';
        }
    }
    #flashChevron(left) {
    this.#logChevronDiagnostic('chevron:flash', { direction: left ? 'left' : 'right' });
    this.view.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
    detail: {
    leftOpacity: left ? 1 : 0,
    rightOpacity: left ? 0 : 1,
    holdMs: 260,
    fadeMs: 200,
    source: 'keyboard'
    }
    }))
    }
    #requestProgressScrubEnd(cancelRequested) {
    if (!this.#progressScrubState) return;
    this.#progressScrubState.pendingEnd = true;
    this.#progressScrubState.cancelRequested = !!cancelRequested;
    this.#progressScrubState.pendingCommit = true; // mark origin fixed for next relocate
    if (this.#progressScrubState.timeoutId) {
    clearTimeout(this.#progressScrubState.timeoutId);
    }
    const cancel = this.#progressScrubState.cancelRequested;
    this.#logScrubDiagnostic('schedule-scrub-end', {
    cancel,
    });
    this.#progressScrubState.timeoutId = setTimeout(() => {
    this.#finalizeProgressScrubSession({ cancel });
    }, 400);
    }
    #finalizeProgressScrubSession({ cancel } = {}) {
    if (!this.#progressScrubState) return;
    if (this.#progressScrubState.timeoutId) {
    clearTimeout(this.#progressScrubState.timeoutId);
    }
    const descriptor = cancel ? null : this.navHUD?.getCurrentDescriptor();
    this.navHUD?.endProgressScrubSession(descriptor, {
    cancel,
    releaseFraction: this.#progressScrubState.releaseFraction,
    originDescriptor: this.#progressScrubState.originDescriptor ?? null,
    originFraction: this.#progressScrubState.originFraction ?? null,
    });
    this.#logScrubDiagnostic('finalize-scrub-session', {
    cancel,
    });
    this.#progressScrubState = null;
    }

    #isJumpInputValueValid(value) {
    if (typeof value !== 'number' || isNaN(value)) return false;
    return value >= 0 && value <= 100 && value !== this.lastPercentValue;
    }

    #computeSectionTicks(pageCountsMap) {
        if (!this.book || !Array.isArray(this.book.sections)) return [];
        const ticks = [];
        const counts = [];
        this.book.sections.forEach((section, idx) => {
            if (section?.linear === 'no') return;
            const pageCount = pageCountsMap instanceof Map ? pageCountsMap.get(idx) : null;
            const size = (typeof pageCount === 'number' && pageCount > 0)
                ? pageCount
                : (typeof section?.size === 'number' && section.size > 0 ? section.size : null);
            if (size != null) counts.push(size);
        });
        if (!counts.length) return ticks;
        const total = counts.reduce((a, b) => a + b, 0);
        let sum = 0;
        for (const size of counts.slice(0, -1)) {
            sum += size;
            ticks.push(sum / total);
        }
        if (counts.length >= 50) {
            const THRESHOLD = 0.01;
            const collapsed = [];
            let group = [];
            for (let i = 0; i < ticks.length; ++i) {
                group.push(ticks[i]);
                if (i === ticks.length - 1 || Math.abs(ticks[i + 1] - ticks[i]) > THRESHOLD) {
                    if (group.length > 1) {
                        const avg = group.reduce((a, b) => a + b, 0) / group.length;
                        let closest = group[0];
                        let minDist = Math.abs(avg - closest);
                        for (const t of group) {
                            const dist = Math.abs(avg - t);
                            if (dist < minDist) {
                                minDist = dist;
                                closest = t;
                            }
                        }
                        collapsed.push(closest);
                    } else {
                        collapsed.push(group[0]);
                    }
                    group = [];
                }
            }
            return collapsed;
        }
        return ticks;
    }

    #renderSectionTicks(pageCountsMap, precomputedTicks) {
        if (!this.#tickContainer) return;
        const ticks = precomputedTicks ?? this.#computeSectionTicks(pageCountsMap);
        this.#tickContainer.innerHTML = '';
        const isRTL = this.isRTL;
        for (const tick of ticks) {
            if (!Number.isFinite(tick)) continue;
            const pos = Math.max(0, Math.min(1, tick)) * 100;
            const mark = document.createElement('div');
            mark.className = 'tick';
            mark.style[isRTL ? 'right' : 'left'] = `${pos}%`;
            this.#tickContainer.append(mark);
        }
    }

    #fractionFromLocation(locNumber, totalLocs) {
    if (typeof locNumber !== 'number' || isNaN(locNumber)) return null;
    if (typeof totalLocs !== 'number' || totalLocs <= 0) return null;
    if (totalLocs === 1) return 0;
    const clamped = Math.max(1, Math.min(totalLocs, Math.round(locNumber)));
    return (clamped - 1) / (totalLocs - 1);
    }

    #convertJumpInputValue(value, fromUnit, toUnit) {
    if (typeof value !== 'number' || isNaN(value)) return null;
    if (fromUnit === toUnit) return value;
    return fromUnit === 'percent' && toUnit === 'percent' ? value : null;
    }

    #syncJumpInputWithState(convertedValue = null) {
    const input = this.#jumpInput ?? document.getElementById('percent-jump-input');
    if (!input) return;
    const button = this.#jumpButton ?? document.getElementById('percent-jump-button');
    if (!this.#jumpInput) this.#jumpInput = input;
    if (!this.#jumpButton) this.#jumpButton = button;
    input.min = 0;
    input.max = 100;
    input.step = 'any';
    if (typeof convertedValue === 'number' && !isNaN(convertedValue)) {
    input.value = convertedValue;
    } else if (typeof this.lastPercentValue === 'number') {
    input.value = this.lastPercentValue;
    }
    if (button) {
    button.disabled = true;
    }
    }

    #updateJumpUnitAvailability() {
    const select = this.#jumpUnitSelect ?? document.getElementById('jump-unit-select');
    if (!select) return;
    if (!this.#jumpUnitSelect) this.#jumpUnitSelect = select;
    select.value = 'percent';
    this.jumpUnit = 'percent';
    }
    async #handleKeydown(event) {
        const k = event.key;
        const renderer = this.view.renderer;
        const isRTL = this.isRTL;

        if (k === 'ArrowLeft' || k === 'h') {
            if (isRTL && await renderer.atEnd()) {
                this.buttons.next.click();
            } else if (!isRTL && await renderer.atStart()) {
                this.buttons.prev.click();
            } else {
                await this.view.goLeft();
                this.#flashChevron(true);
            }
        } else if (k === 'ArrowRight' || k === 'l') {
            if (isRTL && await renderer.atStart()) {
                this.buttons.prev.click();
            } else if (!isRTL && await renderer.atEnd()) {
                this.buttons.next.click();
            } else {
                await this.view.goRight();
                this.#flashChevron(false);
            }
        }
    }
    #onGoTo({
        willLoadNewIndex
    }) {
        this.setLoadingIndicator(true);
    }
    #onDidDisplay({}) {
        this.setLoadingIndicator(false);
    }
    #onRendererRelocate({ detail }) {
        const bodyIsLoading = document?.body?.classList?.contains?.('loading') ?? null;
        logBug('relocate:renderer', {
            reason: detail?.reason ?? null,
            sectionIndex: typeof detail?.sectionIndex === 'number' ? detail.sectionIndex : null,
            bodyIsLoading,
        });
        // Failsafe: clear loading even if didDisplay never fires.
        this.setLoadingIndicator(false);
    }
    async #postFallbackReadingProgressMessage({
        reason = 'load',
        sectionIndex = null,
    } = {}) {
        if (!this.hasLoadedLastPosition) return false
        try {
            const resolvedSectionIndex = typeof sectionIndex === 'number'
                ? sectionIndex
                : (typeof this.view?.renderer?.currentIndex === 'number'
                    ? this.view.renderer.currentIndex
                    : null)
            const sections = this.view?.book?.sections ?? []
            const boundedSectionIndex = typeof resolvedSectionIndex === 'number'
                ? Math.max(0, Math.min(sections.length - 1, resolvedSectionIndex))
                : null
            const denominator = sections.length > 1 ? sections.length - 1 : 1
            const fallbackFraction = boundedSectionIndex == null
                ? 0
                : Math.max(0, Math.min(1, boundedSectionIndex / denominator))
            const fallbackCFI = boundedSectionIndex == null
                ? ''
                : (sections[boundedSectionIndex]?.cfi ?? '')
            this.#postUpdateReadingProgressMessage({
                fraction: fallbackFraction,
                cfi: fallbackCFI,
                reason,
                sectionIndex: boundedSectionIndex,
            })
            return true
        } catch (_error) {
            return false
        }
    }

    async #onLoad({
        detail: {
            doc,
            location,
            index
        }
    }) {
        doc.addEventListener('keydown', this.#handleKeydown.bind(this))
        this.#ensureRubyFontOverride(doc)
        const currentPageURL = location ?? doc.location.href
        window.webkit.messageHandlers.updateCurrentContentPage.postMessage({
        topWindowURL: window.top.location.href,
        currentPageURL,
        })
        logEBookPageNum('onLoad:updateCurrentContentPage', {
            topWindowURL: window.top?.location?.href ?? null,
            currentPageURL: currentPageURL ?? null,
        });
        await this.#postFallbackReadingProgressMessage({
            reason: 'load',
            sectionIndex: typeof index === 'number' ? index : null,
        })
    }

    #ensureRubyFontOverride(doc) {
        try {
        const hostVar = document.documentElement?.style?.getPropertyValue('--manabi-ruby-font')?.trim();
        const stack = hostVar && hostVar.length > 0 ? hostVar : DEFAULT_RUBY_FONT_STACK;
        doc.documentElement?.style?.setProperty('--manabi-ruby-font', stack);
        } catch (error) {
        // window.webkit?.messageHandlers?.print?.postMessage?.({
        // message: 'RUBY_FONT_OVERRIDE_ERROR',
        // error: String(error),
        // pageURL: doc.location?.href ?? null
        // });
        }
    }

    #resetSideNavChevrons() {
        this.#chevronAnimator?.reset();
    }

    #deriveRelocateDirection(detail, { previousFraction = null, previousPageEstimate = null } = {}) {
        const explicit = detail?.navigationDirection ?? detail?.direction ?? detail?.pageTurnDirection;
        if (explicit === 'forward' || explicit === 'backward') {
            return explicit;
        }

        const currentPage = typeof detail?.pageItem?.current === 'number' ? detail.pageItem.current : null;
        const lastPage = typeof previousPageEstimate?.current === 'number' ? previousPageEstimate.current : null;
        if (currentPage != null && lastPage != null) {
            if (currentPage > lastPage) return 'forward';
            if (currentPage < lastPage) return 'backward';
        }

        const priorFraction = typeof previousFraction === 'number' ? previousFraction : null;
        const nextFraction = typeof detail?.fraction === 'number' ? detail.fraction : null;
        if (priorFraction != null && nextFraction != null) {
            const delta = nextFraction - priorFraction;
            const EPSILON = 0.000001;
            if (delta > EPSILON) return 'forward';
            if (delta < -EPSILON) return 'backward';
        }

        return null;
    }

    #postUpdateReadingProgressMessage = debounce(({
    fraction,
    cfi,
    reason,
    sectionIndex
    }) => {
    let mainDocumentURL = (window.location != window.parent.location) ? document.referrer : document.location.href
    try {
    window.webkit.messageHandlers.updateReadingProgress.postMessage({
    fractionalCompletion: fraction,
    cfi: cfi,
    reason: reason,
    sectionIndex: typeof sectionIndex === 'number' ? sectionIndex : null,
    mainDocumentURL: mainDocumentURL,
    })
    } catch (error) {
    console.error('Failed to post updateReadingProgress', error)
    }
    }, 400)

    async #onRelocate({ detail }) {
        const sectionIndexFromDetail =
            typeof detail?.sectionIndex === 'number' ? detail.sectionIndex :
            (typeof detail?.index === 'number' ? detail.index : null);
        const fractionFromDetail = typeof detail?.fraction === 'number' ? detail.fraction : null;
        try {
        // Make sure any loading overlay from the previous navigation is cleared.
        this.setLoadingIndicator(false);
        const navBar = document.getElementById('nav-bar');
        const progressWrapper = document.getElementById('progress-wrapper');
        const sliderEl = document.getElementById('progress-slider');
        const ticksEl = document.getElementById('progress-ticks');
        logBug('relocate:start', {
            reason: detail?.reason ?? null,
            sectionIndex: sectionIndexFromDetail,
            fraction: fractionFromDetail,
            bodyClasses: Array.from(document?.body?.classList ?? []),
            navHidden: navBar?.classList?.contains?.('nav-hidden') ?? null,
            sliderVisible: sliderEl?.style?.visibility ?? null,
        });

        // Previously forced nav visible on every relocate for debugging; that caused flicker when crossing sections.
        // Keep state untouched so forward page turns can hide the nav without being re-shown here.
        logNavHide('relocate:preserve-nav-state', {
            source: detail?.reason ?? null,
            navHiddenClass: navBar?.classList?.contains?.('nav-hidden') ?? null,
            navHiddenScrollClass: navBar?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null,
            bodyNavHidden: document?.body?.classList?.contains?.('nav-hidden') ?? null,
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
            pendingHideNavigationState,
        });

        const {
            fraction,
            location,
            tocItem,
            pageItem,
            cfi,
            reason,
            index: sectionIndex
        } = detail
        // Normalize section index so downstream HUD can aggregate page counts reliably.
        const inferredSectionIndex = (() => {
            if (typeof detail?.sectionIndex === 'number') return detail.sectionIndex
            if (typeof sectionIndex === 'number') return sectionIndex
            const rendererIndex = this.view?.renderer?.currentIndex
            if (typeof rendererIndex === 'number') return rendererIndex
            return null
        })()
        const normalizedDetail = {
                ...detail,
                sectionIndex: inferredSectionIndex,
                index: typeof detail?.index === 'number'
                    ? detail.index
                    : (typeof sectionIndex === 'number' ? sectionIndex : inferredSectionIndex),
            }
        const previousFraction = typeof this.lastKnownFraction === 'number' ? this.lastKnownFraction : null;
        const previousPageEstimate = this.lastPageEstimate;
        const slider = $('#progress-slider')
        slider.style.visibility = 'visible'
        const ticks = document.getElementById('progress-ticks');
        if (ticks) ticks.style.visibility = 'visible'
        // (removed: setting tocView currentHref here)
        const scrubbing = !!this.#progressScrubState;
        if (scrubbing) {
            detail.reason = 'live-scroll';
            detail.liveScrollPhase = 'dragging';
        } else if (detail.reason === 'live-scroll') {
            detail.liveScrollPhase = 'settled';
        }

        const normalizedReason = (detail.reason || '').toLowerCase();
        const relocateDirection = this.#deriveRelocateDirection(detail, {
            previousFraction,
            previousPageEstimate,
        });
        const sectionDelta = (typeof sectionIndex === 'number' && typeof this._lastRelocateSectionIndex === 'number')
            ? sectionIndex - this._lastRelocateSectionIndex
            : null;
        logNavHide('relocate:direction', {
            reason: normalizedReason,
            direction: relocateDirection,
            previousFraction,
            fraction,
            previousSectionIndex: this._lastRelocateSectionIndex ?? null,
            sectionIndex,
            bodyNavHidden: document?.body?.classList?.contains?.('nav-hidden') ?? null,
            navHiddenScrollClass: navBar?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null,
            hideNavigationDueToScroll: this.navHUD?.hideNavigationDueToScroll ?? null,
            sectionDelta,
        });
        switch (normalizedReason) {
        case 'live-scroll':
        case 'selection':
        case 'navigation':
            postNavigationChromeVisibility(false, {
                source: 'relocate',
                direction: relocateDirection,
                scrubbing,
                ctx: { sectionIndex, fraction, previousFraction, reason: normalizedReason },
            });
            break;
        case 'page':
            if (scrubbing) {
                postNavigationChromeVisibility(false, {
                    source: 'relocate',
                    direction: relocateDirection,
                    scrubbing,
                    ctx: { sectionIndex, fraction, previousFraction, reason: normalizedReason },
                });
            } else if (relocateDirection === 'forward') {
                postNavigationChromeVisibility(true, {
                    source: 'relocate',
                    direction: 'forward',
                    scrubbing,
                    ctx: { sectionIndex, fraction, previousFraction, reason: normalizedReason },
                });
            } else if (relocateDirection === 'backward') {
                postNavigationChromeVisibility(false, {
                    source: 'relocate',
                    direction: 'backward',
                    scrubbing,
                    ctx: { sectionIndex, fraction, previousFraction, reason: normalizedReason },
                });
            } else {
                postNavigationChromeVisibility(false, {
                    source: 'relocate',
                    direction: relocateDirection,
                    scrubbing,
                    ctx: { sectionIndex, fraction, previousFraction, reason: normalizedReason },
                });
            }
                logBug('nav-toggle', {
                    reason: normalizedReason,
                    direction: relocateDirection,
                    hide: relocateDirection === 'forward',
                    fraction,
                    sectionIndex,
                });
                break;
            default:
                break;
            }

        if (this.hasLoadedLastPosition) {
            this.#postUpdateReadingProgressMessage({
                fraction,
                cfi,
                reason,
                sectionIndex: normalizedDetail.sectionIndex,
            })
        }

        await this.updateNavButtons();
        await this.navHUD?.handleRelocate(normalizedDetail);
        this._lastRelocateContext = {
            fraction,
            sectionIndex,
            reason: normalizedReason,
            relocateDirection,
            previousFraction,
        };
        const scrubFraction = this.navHUD?.getScrubberFraction(normalizedDetail) ?? null;
        const effectiveFraction = Number.isFinite(scrubFraction) ? scrubFraction : fraction;
        if ((detail.reason || '').toLowerCase() !== 'live-scroll') {
            const sliderValue = Number.isFinite(effectiveFraction) ? effectiveFraction : 0;
            slider.value = sliderValue;
            slider.style.setProperty('--value', sliderValue); // keep slider progress updated
        }
        const percentValue = Number.isFinite(effectiveFraction) ? effectiveFraction : 0;
        const percent = percentFormat.format(percentValue);
        const navLabel = this.navHUD?.getPrimaryDisplayLabel(normalizedDetail);
        const tooltipParts = [];
        if (navLabel) {
            tooltipParts.push(navLabel);
        }
        tooltipParts.push(percent);
        slider.title = tooltipParts.filter(Boolean).join(' · ');
        if (scrubbing && this.#progressScrubState?.pendingEnd) {
            this.#finalizeProgressScrubSession({ cancel: this.#progressScrubState.cancelRequested });
        }

        this.lastKnownFraction = percentValue;
        const pct = Math.round(percentValue * 100);
        this.lastPercentValue = pct;
        const percentInput = this.#jumpInput ?? document.getElementById('percent-jump-input');
        const percentButton = this.#jumpButton ?? document.getElementById('percent-jump-button');
        if (!this.#jumpInput && percentInput) this.#jumpInput = percentInput;
        if (!this.#jumpButton && percentButton) this.#jumpButton = percentButton;
            const pageEstimate = this.navHUD?.getPageEstimate(normalizedDetail);
            if (pageEstimate) {
                this.lastPageEstimate = pageEstimate;
            }
        logEBookPageNum('relocate:label', {
            label: navLabel ?? '',
            fraction,
            scrubFraction: scrubFraction ?? null,
            sectionIndex,
            pageEstimateCurrent: pageEstimate?.current ?? null,
            pageEstimateTotal: pageEstimate?.total ?? null,
            lastPercentValue: this.lastPercentValue ?? null,
        });
        logEBookPageNum('relocate', {
            reason: detail.reason ?? null,
            relocateDirection,
            sectionIndex,
            fraction,
            scrubFraction: scrubFraction ?? null,
            pageItemCurrent: pageItem?.current ?? null,
            pageItemTotal: pageItem?.total ?? null,
            locationCurrent: location?.current ?? null,
            locationTotal: location?.total ?? null,
            tocHref: tocItem?.href ?? null,
            pageEstimateCurrent: pageEstimate?.current ?? null,
            pageEstimateTotal: pageEstimate?.total ?? null,
            previousPageEstimateCurrent: previousPageEstimate?.current ?? null,
            previousPageEstimateTotal: previousPageEstimate?.total ?? null,
            previousFraction,
            lastPercentValue: this.lastPercentValue ?? null,
            scrubbing,
        });
        this._lastRelocateSectionIndex = sectionIndex;
        this.#updateJumpUnitAvailability();
        this.#syncJumpInputWithState();
            if (percentButton) {
                percentButton.disabled = true;
            }
            logBug('relocate:end', {
                reason: detail?.reason ?? null,
                sectionIndex: sectionIndexFromDetail,
                fraction,
                scrubFraction: scrubFraction ?? null,
                pageEstimateCurrent: this.lastPageEstimate?.current ?? null,
                pageEstimateTotal: this.lastPageEstimate?.total ?? null,
                navHiddenClass: document?.body?.classList?.contains?.('nav-hidden') ?? null,
            });
        } catch (error) {
            logBug('relocate:error', { message: String(error), stack: error?.stack ?? null });
            console.error(error);
        }
    }

    async #goToDescriptor(descriptor) {
        if (!descriptor) return;
        const fraction = typeof descriptor.fraction === 'number' ? Number(descriptor.fraction.toFixed(6)) : null;
        // const line = fraction != null
        // ? `# JUMPBACK goToDescriptor ${JSON.stringify({ fraction })}`
        // : `# JUMPBACK goToDescriptor ${JSON.stringify({ hasCFI: !!descriptor.cfi })}`;
        if (descriptor.cfi) {
            await this.view.goTo(descriptor.cfi);
            return;
        }
        if (typeof descriptor.fraction === 'number') {
            await this.view.goToFraction(descriptor.fraction);
        }
    }

    async #onNavButtonClick(e) {
        const btn = e.currentTarget;
        const type = btn.dataset.buttonType;
        // const line = `# EBOOK nav:click ${JSON.stringify({ type })}`;
        // For spinner placement
        const icon = btn.querySelector('svg');
        const label = btn.querySelector('.button-label');
        // Hide the label while loading
        if (label) label.style.visibility = 'hidden';
        // Replace SVG icon with spinner, respecting spinner placement
        if (icon) {
            btn._originalIcon = icon.cloneNode(true);
            const spinner = document.createElement('div');
            spinner.className = 'ispinner nav-spinner';
            spinner.innerHTML = '<div class="ispinner-blade"></div>'.repeat(8);

            // Improved spinner placement for RTL/LTR
            if (btn._spinnerAfterLabel) {
                if (icon) icon.remove();
                // Find the last visible .button-label
                const labels = btn.querySelectorAll('.button-label');
                let targetLabel = null;
                for (const lbl of labels) {
                    if (lbl.offsetParent !== null && getComputedStyle(lbl).display !== 'none') {
                        targetLabel = lbl;
                    }
                }
                if (targetLabel) {
                    targetLabel.after(spinner);
                } else {
                    btn.appendChild(spinner);
                }
            } else {
                // Default: replace icon with spinner
                icon.replaceWith(spinner);
            }
        }
        const restoreIcon = () => {
            const spinner = btn.querySelector('.ispinner.nav-spinner');
            if (spinner && btn._originalIcon) {
                spinner.replaceWith(btn._originalIcon);
                delete btn._originalIcon;
            }
            if (label) label.style.visibility = '';
        };
        let nav;
        switch (type) {
        // TODO: Clean up, the scroll cases here won't be reached because of above...
        case 'prev':
            postNavigationChromeVisibility(false, { source: 'button-prev', direction: 'backward' });
            nav = this.view.renderer.prevSection();
            break;
        case 'next':
            postNavigationChromeVisibility(true, { source: 'button-next', direction: 'forward', scrubbing: false });
            nav = this.view.renderer.nextSection();
            break;
        case 'finish':
            window.webkit.messageHandlers.finishedReadingBook.postMessage({
                topWindowURL: window.top.location.href,
            });
            nav = Promise.resolve();
            break;
        case 'restart':
            window.webkit.messageHandlers.startOver.postMessage({});
            await this.view.renderer.firstSection();
            nav = Promise.resolve();
            break;
        }
        Promise.resolve(nav).catch(err => {
            const line = `# EBOOK nav:error ${JSON.stringify({ type, message: err?.message ?? String(err) })}`;
            // try { window.webkit?.messageHandlers?.print?.postMessage?.(line); console.log(line); } catch (_) {}
        }).finally(() => {
            // Keep spinner for 'finish' or 'restart' – Swift layer will handle refresh
            if (type === 'finish' || type === 'restart') return;
            restoreIcon();
        });
    }
}

class CacheWarmer {
    constructor() {
        this.view
        this.pageCounts = new Map()
        globalThis.cacheWarmerPageCounts = this.pageCounts
        globalThis.cacheWarmerTotalPages = 0
    }
    async open(source) {
    this.source = source
    this.view = await getView(source, true)
    this.view.addEventListener('load', this.#onLoad.bind(this))
    this.view.addEventListener('relocate', this.#onRelocate.bind(this))

    const {
    book
    } = this.view
    this.view.renderer.setAttribute('flow', 'paginated')
    //        this.view.renderer.next()

    await this.view.renderer.firstSection()
    }

    async #onLoad({
        detail: {
            location
        }
    }) {
        window.webkit.messageHandlers.ebookCacheWarmerLoadedSection.postMessage({
            topWindowURL: window.top.location.href,
            frameURL: location,
        })

        if (!(await this.view.renderer.atEnd())) {
            window.webkit.messageHandlers.ebookCacheWarmerReadyToLoadNextSection.postMessage({
                topWindowURL: window.top.location.href,
            })
        } else {
            //            this.view.remove()
        }
    }

    #broadcastPageCounts() {
        const total = Array.from(this.pageCounts.values()).reduce((acc, v) => acc + (Number.isFinite(v) ? v : 0), 0)
        globalThis.cacheWarmerTotalPages = total
        try {
            const key = getBookCacheKey();
            if (key) {
                const handler = globalThis.webkit?.messageHandlers?.[MANABI_TRACKING_CACHE_HANDLER];
                handler?.postMessage?.({
                    command: 'set',
                    key: `${key}::pageCounts`,
                    entries: Array.from(this.pageCounts.entries()),
                    reason: 'page-counts',
                });
                logFix('cachewarmer:store', { key, total, size: this.pageCounts.size });
            }
        } catch (error) {
            logFix('cachewarmer:store:error', { error: String(error) });
        }
        document.dispatchEvent(new CustomEvent('cachewarmer:pagecounts', {
            detail: {
                counts: Array.from(this.pageCounts.entries()),
                total,
            }
        }))
    }

    #onRelocate({ detail }) {
        const sectionIndex = typeof detail?.sectionIndex === 'number'
            ? detail.sectionIndex
            : (typeof this.view?.renderer?.currentIndex === 'number' ? this.view.renderer.currentIndex : null)
        const pageCount = typeof detail?.pageCount === 'number' && detail.pageCount > 0 ? detail.pageCount : null
        if (sectionIndex == null || pageCount == null) return
        this.pageCounts.set(sectionIndex, pageCount)
        this.#broadcastPageCounts()
    }

    //    #postUpdateReadingProgressMessage = debounce(({ fraction, cfi }) => {
    //        let mainDocumentURL = (window.location != window.parent.location) ? document.referrer : document.location.href
    //        window.webkit.messageHandlers.updateReadingProgress.postMessage({
    //        fractionalCompletion: fraction,
    //        cfi: cfi,
    //        mainDocumentURL: mainDocumentURL,
    //        })
    //    }, 400)
}

//const open = async file => {
//    document.body.removeChild($('#drop-target'))
//    const reader = new Reader()
//    globalThis.reader = reader
//    await reader.open(file)
//}

//const params = new URLSearchParams(location.search)
//const url = params.get('url')
//if (url) fetch(url)
//    .then(res => res.blob())
//    .then(blob => open(new File([blob], new URL(url).pathname)))
//    .catch(e => console.error(e))
//else dropTarget.style.visibility = 'visible'

const getVisibleReaderFrames = () => {
    const frames = Array.from(document.querySelectorAll('iframe'));
    if (!frames.length) { return []; }
    const viewportHeight = window.innerHeight || document.documentElement?.clientHeight || 0;
    const viewportWidth = window.innerWidth || document.documentElement?.clientWidth || 0;
    return frames
        .map((frame) => {
            try {
                const frameWindow = frame.contentWindow;
                const frameDocument = frameWindow?.document;
                const hasReaderContent = !!frameDocument?.querySelector?.('manabi-sentence[data-sentence-identifier]');
                if (!hasReaderContent) { return null; }
                const rect = frame.getBoundingClientRect();
                const visibleWidth = Math.max(0, Math.min(rect.right, viewportWidth) - Math.max(rect.left, 0));
                const visibleHeight = Math.max(0, Math.min(rect.bottom, viewportHeight) - Math.max(rect.top, 0));
                const visibleArea = visibleWidth * visibleHeight;
                return { frame, visibleArea };
            } catch (_error) {
                return null;
            }
        })
        .filter(Boolean)
        .sort((lhs, rhs) => rhs.visibleArea - lhs.visibleArea)
        .map((entry) => entry.frame);
};

const callFrameFunction = (frame, functionName, args = []) => {
    try {
        const frameWindow = frame?.contentWindow;
        const fn = frameWindow?.[functionName];
        if (typeof fn !== 'function') { return null; }
        return fn.apply(frameWindow, args);
    } catch (_error) {
        return null;
    }
};

const resolvePrimaryReaderFrame = () => {
    const frames = getVisibleReaderFrames();
    return frames[0] || null;
};

window.manabi_collectSentencesForAITTS = () => {
    const frame = resolvePrimaryReaderFrame();
    if (!frame) { return []; }
    const rows = callFrameFunction(frame, 'manabi_collectSentencesForAITTS');
    return Array.isArray(rows) ? rows : [];
};

window.manabi_captureVisibleSentenceIdentifier = () => {
    const frame = resolvePrimaryReaderFrame();
    if (!frame) { return null; }
    return callFrameFunction(frame, 'manabi_captureVisibleSentenceIdentifier');
};

window.manabi_setAITTSCurrentSentence = (sentenceIdentifier) => {
    let didApply = false;
    const frames = getVisibleReaderFrames();
    for (const frame of frames) {
        const appliedInFrame = callFrameFunction(frame, 'manabi_setAITTSCurrentSentence', [sentenceIdentifier]);
        if (appliedInFrame === true) {
            didApply = true;
        }
    }
    return didApply;
};

window.manabi_clearAITTSCurrentSentence = () => {
    const frames = getVisibleReaderFrames();
    for (const frame of frames) {
        callFrameFunction(frame, 'manabi_clearAITTSCurrentSentence');
    }
    return true;
};

window.manabi_seekToSentenceIdentifierForReadAloud = (sentenceIdentifier) => {
    if (!sentenceIdentifier) { return false; }
    const frames = getVisibleReaderFrames();
    for (const frame of frames) {
        const didSeek = callFrameFunction(frame, 'manabi_seekToSentenceIdentifierForReadAloud', [sentenceIdentifier]);
        if (didSeek === true) {
            return true;
        }
    }
    return false;
};

window.manabi_getPlaybackSyncAnchor = () => {
    const frame = resolvePrimaryReaderFrame();
    if (!frame) {
        const sliderVisibility = (() => {
            if (!slider || !slider.isConnected) return null;
            const computedStyle = window.getComputedStyle?.(slider);
            if (!computedStyle) return null;
            return computedStyle.visibility !== 'hidden'
                && computedStyle.display !== 'none'
                && computedStyle.opacity !== '0';
        })();
        return {
            sentenceIdentifier: null,
            transcriptStartSeconds: null,
        };
    }
    const anchor = callFrameFunction(frame, 'manabi_getPlaybackSyncAnchor');
    if (anchor && typeof anchor === 'object') {
        return anchor;
    }
    return {
        sentenceIdentifier: null,
        transcriptStartSeconds: null,
    };
};

window.manabi_shouldSeekPlaybackAfterViewportCheck = async (options = {}) => {
    const frame = resolvePrimaryReaderFrame();
    if (!frame) {
        return true;
    }
    const frameWindow = frame.contentWindow;
    if (typeof frameWindow?.manabi_shouldSeekPlaybackAfterViewportCheck !== 'function') {
        return true;
    }
    try {
        const result = await frameWindow.manabi_shouldSeekPlaybackAfterViewportCheck(options);
        return result !== false;
    } catch (_error) {
        return true;
    }
};


const manabiEbookAudioBridge = {
    pausedForLoading: false,
    pendingNavigation: null,
    requestNavigation(payload) {
    if (!payload) { return; }
    const fraction = this.fractionForPayload(payload);
    if (!Number.isFinite(fraction)) { return; }
    if (this.pendingNavigation && Math.abs((this.pendingNavigation.fraction ?? fraction) - fraction) < 0.0001) {
    return;
    }
    this.pendingNavigation = Object.assign({}, payload, { fraction });
    this.pauseNativeAudio('section-navigation');
    globalThis.reader?.view?.goToFraction(fraction).catch(error => {
    console.error('ebook audio navigation failed', error);
    this.resumeNativeAudio('navigation-error');
    });
    },
    sectionReady(metadata) {
    if (metadata?.sectionURL) {
    this.pendingNavigation = null;
    }
    this.resumeNativeAudio('section-ready');
    },
    cancel(reason = 'cancelled') {
    this.pendingNavigation = null;
    if (this.pausedForLoading) {
    this.resumeNativeAudio(reason);
    }
    },
    fractionForPayload(payload) {
    if (Number.isFinite(payload?.fraction)) {
    return Math.max(0, Math.min(1, payload.fraction));
    }
    if (Number.isFinite(payload?.wordIndex) && Number.isFinite(payload?.totalWordCount) && payload.totalWordCount > 0) {
    return Math.max(0, Math.min(1, payload.wordIndex / payload.totalWordCount));
    }
    return null;
    },
    pauseNativeAudio(reason) {
    if (this.pausedForLoading) { return; }
    this.pausedForLoading = true;
    try {
    window.webkit?.messageHandlers?.ebookAudioLoadingState?.postMessage?.({ action: 'pause', reason, timestamp: Date.now() });
    } catch (_error) {
    // ignore
    }
    },
    resumeNativeAudio(reason) {
    if (!this.pausedForLoading) { return; }
    this.pausedForLoading = false;
    try {
    window.webkit?.messageHandlers?.ebookAudioLoadingState?.postMessage?.({ action: 'resume', reason, timestamp: Date.now() });
    } catch (_error) {
    // ignore
    }
    }
};
window.manabiEbookAudioBridge = manabiEbookAudioBridge;

window.cancelEbookAudioNavigation = (reason) => {
    window.manabiEbookAudioBridge?.cancel?.(reason || 'cancelled');
};

window.setEbookViewerLayout = (layoutMode) => {
    // TODO: Add scrolled mode back...
    //    globalThis.reader.view.renderer.setAttribute('flow', layoutMode)
}

window.setEbookViewerWritingDirection = async (writingDirection) => {
    globalThis.manabiEbookWritingDirection = writingDirection || 'original';
    const renderer = globalThis.reader?.view?.renderer;
    if (renderer && typeof renderer.render === 'function') {
        try {
            await renderer.render();
        } catch (_) {
            // best effort
        }
    }
    try {
        const currentDoc = globalThis.reader?.view?.document;
        if (currentDoc) {
            await globalThis.manabiEnsureCustomFonts?.(currentDoc);
        }
    } catch (_) {}
}

window.manabiGetWritingDirectionSnapshot = () => {
    return {
        pageURL: window.location.href,
        writingDirectionOverride: globalThis.manabiEbookWritingDirection || 'original',
        vertical: globalThis.manabiTrackingVertical === true,
        verticalRTL: globalThis.manabiTrackingVerticalRTL === true,
        rtl: globalThis.manabiTrackingRTL === true,
        writingMode: globalThis.manabiTrackingWritingMode || null,
    };
}

window.loadNextCacheWarmerSection = async () => {
    await window.cacheWarmer.view.renderer.nextSection()
}

const throttle = (fn, intervalMs = 200) => {
    let last = 0;
    return (...args) => {
        const now = Date.now();
        if (now - last >= intervalMs) {
            last = now;
            return fn(...args);
        }
    };
};

const logReaderBootstrapState = (event) => {
    logFix(event, {
        hasReader: !!globalThis.reader,
        hasView: !!globalThis.reader?.view,
        hasRenderer: !!globalThis.reader?.view?.renderer,
        hasSectionLayoutController: !!(
            globalThis.reader?.view?.document?.defaultView?.manabiEbookSectionLayoutController
            ?? globalThis.manabiEbookSectionLayoutController
        ),
        pageURL: window.location.href,
    });
};

window.manabiGetPageTurnProbeSnapshot = async () => {
    try {
        const view = globalThis.reader?.view;
        const renderer = view?.renderer;
        const sectionLayoutController = view?.document?.defaultView?.manabiEbookSectionLayoutController
            ?? globalThis.manabiEbookSectionLayoutController;
        let layoutDiagnostics = typeof sectionLayoutController?.layoutDiagnostics === 'function'
            ? sectionLayoutController.layoutDiagnostics()
            : null;
        const chunkLayoutMetrics = typeof globalThis.manabiGetChunkLayoutMetrics === 'function'
            ? globalThis.manabiGetChunkLayoutMetrics({ isEbook: true })
            : null;
        const layoutCurrentPageIndex = Number.isFinite(layoutDiagnostics?.currentPageIndex)
            ? layoutDiagnostics.currentPageIndex
            : null;
        if (
            Number.isFinite(layoutCurrentPageIndex)
            && typeof sectionLayoutController?.ensurePageBuilt === 'function'
            && (!Number.isFinite(layoutDiagnostics?.pageCount) || layoutDiagnostics.pageCount <= layoutCurrentPageIndex + 1)
        ) {
            try {
                sectionLayoutController.ensurePageBuilt(layoutCurrentPageIndex + 1, {
                    reason: 'page-turn-probe',
                });
                layoutDiagnostics = typeof sectionLayoutController?.layoutDiagnostics === 'function'
                    ? sectionLayoutController.layoutDiagnostics()
                    : layoutDiagnostics;
            } catch (_error) {}
        }
        const shouldAttemptOverflowRecovery =
            typeof sectionLayoutController?.rebuildFromCurrentLocation === 'function'
            && layoutDiagnostics?.layoutComplete === true
            && Number.isFinite(layoutDiagnostics?.pageCount)
            && layoutDiagnostics.pageCount <= 1
            && layoutDiagnostics?.currentChunkOverflow === true
            && !globalThis.manabiPageTurnOverflowRecoveryAttempted;
        if (shouldAttemptOverflowRecovery) {
            try {
                globalThis.manabiPageTurnOverflowRecoveryAttempted = true;
                sectionLayoutController.rebuildFromCurrentLocation({
                    reason: 'page-turn-probe-overflow-rebuild',
                });
                layoutDiagnostics = typeof sectionLayoutController?.layoutDiagnostics === 'function'
                    ? sectionLayoutController.layoutDiagnostics()
                    : layoutDiagnostics;
            } catch (_error) {}
        }
        const layoutPageCount = Number.isFinite(layoutDiagnostics?.pageCount)
            ? layoutDiagnostics.pageCount
            : null;
        const layoutPageRecordCount = Number.isFinite(layoutDiagnostics?.pageRecordCount)
            ? layoutDiagnostics.pageRecordCount
            : (Array.isArray(layoutDiagnostics?.pages) ? layoutDiagnostics.pages.length : null);
        const layoutLiveRootExists = typeof layoutDiagnostics?.liveRootExists === 'boolean'
            ? layoutDiagnostics.liveRootExists
            : null;
        const layoutLiveRootClassName = typeof layoutDiagnostics?.liveRootClassName === 'string'
            ? layoutDiagnostics.liveRootClassName
            : null;
        const layoutLiveRootChildCount = Number.isFinite(layoutDiagnostics?.liveRootChildCount)
            ? layoutDiagnostics.liveRootChildCount
            : null;
        const layoutLiveRootRectWidth = Number.isFinite(layoutDiagnostics?.liveRootRectWidth)
            ? layoutDiagnostics.liveRootRectWidth
            : null;
        const layoutLiveRootRectHeight = Number.isFinite(layoutDiagnostics?.liveRootRectHeight)
            ? layoutDiagnostics.liveRootRectHeight
            : null;
        const layoutLiveCurrentPageExists = typeof layoutDiagnostics?.liveCurrentPageExists === 'boolean'
            ? layoutDiagnostics.liveCurrentPageExists
            : null;
        const layoutLiveCurrentPageClassName = typeof layoutDiagnostics?.liveCurrentPageClassName === 'string'
            ? layoutDiagnostics.liveCurrentPageClassName
            : null;
        const layoutLiveCurrentPageRectWidth = Number.isFinite(layoutDiagnostics?.liveCurrentPageRectWidth)
            ? layoutDiagnostics.liveCurrentPageRectWidth
            : null;
        const layoutLiveCurrentPageRectHeight = Number.isFinite(layoutDiagnostics?.liveCurrentPageRectHeight)
            ? layoutDiagnostics.liveCurrentPageRectHeight
            : null;
        const layoutLiveCurrentPageContainsChunkBody = typeof layoutDiagnostics?.liveCurrentPageContainsChunkBody === 'boolean'
            ? layoutDiagnostics.liveCurrentPageContainsChunkBody
            : null;
        const layoutLiveCurrentChunkExists = typeof layoutDiagnostics?.liveCurrentChunkExists === 'boolean'
            ? layoutDiagnostics.liveCurrentChunkExists
            : null;
        const layoutLiveCurrentChunkTagName = typeof layoutDiagnostics?.liveCurrentChunkTagName === 'string'
            ? layoutDiagnostics.liveCurrentChunkTagName
            : null;
        const layoutLiveCurrentChunkClassName = typeof layoutDiagnostics?.liveCurrentChunkClassName === 'string'
            ? layoutDiagnostics.liveCurrentChunkClassName
            : null;
        const layoutLiveCurrentChunkDisplay = typeof layoutDiagnostics?.liveCurrentChunkDisplay === 'string'
            ? layoutDiagnostics.liveCurrentChunkDisplay
            : null;
        const layoutLiveCurrentChunkPosition = typeof layoutDiagnostics?.liveCurrentChunkPosition === 'string'
            ? layoutDiagnostics.liveCurrentChunkPosition
            : null;
        const layoutLiveCurrentChunkFlex = typeof layoutDiagnostics?.liveCurrentChunkFlex === 'string'
            ? layoutDiagnostics.liveCurrentChunkFlex
            : null;
        const layoutLiveCurrentChunkRectWidth = Number.isFinite(layoutDiagnostics?.liveCurrentChunkRectWidth)
            ? layoutDiagnostics.liveCurrentChunkRectWidth
            : null;
        const layoutLiveCurrentChunkRectHeight = Number.isFinite(layoutDiagnostics?.liveCurrentChunkRectHeight)
            ? layoutDiagnostics.liveCurrentChunkRectHeight
            : null;
        const layoutLiveCurrentChunkInnerHTMLLength = Number.isFinite(layoutDiagnostics?.liveCurrentChunkInnerHTMLLength)
            ? layoutDiagnostics.liveCurrentChunkInnerHTMLLength
            : null;
        const layoutLiveCurrentChunkContainsChunkBody = typeof layoutDiagnostics?.liveCurrentChunkContainsChunkBody === 'boolean'
            ? layoutDiagnostics.liveCurrentChunkContainsChunkBody
            : null;
        const layoutLiveCurrentChunkChildCount = Number.isFinite(layoutDiagnostics?.liveCurrentChunkChildCount)
            ? layoutDiagnostics.liveCurrentChunkChildCount
            : null;
        const layoutLiveCurrentChunkTextLength = Number.isFinite(layoutDiagnostics?.liveCurrentChunkTextLength)
            ? layoutDiagnostics.liveCurrentChunkTextLength
            : null;
        const layoutCurrentChunkBodyChildCount = Number.isFinite(layoutDiagnostics?.currentChunkBodyChildCount)
            ? layoutDiagnostics.currentChunkBodyChildCount
            : null;
        const layoutCurrentChunkBodyTextLength = Number.isFinite(layoutDiagnostics?.currentChunkBodyTextLength)
            ? layoutDiagnostics.currentChunkBodyTextLength
            : null;
        const layoutCurrentChunkBodyDisplay = typeof layoutDiagnostics?.currentChunkBodyDisplay === 'string'
            ? layoutDiagnostics.currentChunkBodyDisplay
            : null;
        const layoutCurrentChunkBodyPosition = typeof layoutDiagnostics?.currentChunkBodyPosition === 'string'
            ? layoutDiagnostics.currentChunkBodyPosition
            : null;
        const layoutCurrentChunkBodyFlex = typeof layoutDiagnostics?.currentChunkBodyFlex === 'string'
            ? layoutDiagnostics.currentChunkBodyFlex
            : null;
        const layoutColumnCount = Number.isFinite(layoutDiagnostics?.columnCount)
            ? layoutDiagnostics.columnCount
            : null;
        const layoutCurrentPageChunkCount = Number.isFinite(layoutDiagnostics?.currentPageChunkCount)
            ? layoutDiagnostics.currentPageChunkCount
            : null;
        const layoutMaxPageChunkCount = Number.isFinite(layoutDiagnostics?.maxPageChunkCount)
            ? layoutDiagnostics.maxPageChunkCount
            : null;
        const layoutUnitCount = Number.isFinite(layoutDiagnostics?.unitCount)
            ? layoutDiagnostics.unitCount
            : null;
        const layoutActiveBuildPageIndex = Number.isFinite(layoutDiagnostics?.activeBuildPageIndex)
            ? layoutDiagnostics.activeBuildPageIndex
            : null;
        const layoutComplete = typeof layoutDiagnostics?.layoutComplete === 'boolean'
            ? layoutDiagnostics.layoutComplete
            : null;
        const layoutSpreadCandidateDetected = typeof layoutDiagnostics?.spreadCandidateDetected === 'boolean'
            ? layoutDiagnostics.spreadCandidateDetected
            : null;
        const layoutVisibleUnitKind = typeof layoutDiagnostics?.visibleUnitKind === 'string'
            ? layoutDiagnostics.visibleUnitKind
            : null;
        const layoutVisibleUnitAxis = typeof layoutDiagnostics?.visibleUnitAxis === 'string'
            ? layoutDiagnostics.visibleUnitAxis
            : null;
        const layoutVisiblePageCount = Number.isFinite(layoutDiagnostics?.visiblePageCount)
            ? layoutDiagnostics.visiblePageCount
            : null;
        const layoutCurrentUnitIndex = Number.isFinite(layoutDiagnostics?.currentUnitIndex)
            ? layoutDiagnostics.currentUnitIndex
            : null;
        const layoutLeadingPageIndex = Number.isFinite(layoutDiagnostics?.leadingPageIndex)
            ? layoutDiagnostics.leadingPageIndex
            : null;
        const layoutTrailingPageIndex = Number.isFinite(layoutDiagnostics?.trailingPageIndex)
            ? layoutDiagnostics.trailingPageIndex
            : null;
        const layoutHasLeadingSingleton = typeof layoutDiagnostics?.hasLeadingSingleton === 'boolean'
            ? layoutDiagnostics.hasLeadingSingleton
            : null;
        const layoutHasTrailingSingleton = typeof layoutDiagnostics?.hasTrailingSingleton === 'boolean'
            ? layoutDiagnostics.hasTrailingSingleton
            : null;
        const layoutMultiUnitActive = typeof layoutDiagnostics?.multiUnitActive === 'boolean'
            ? layoutDiagnostics.multiUnitActive
            : null;
        const layoutSpreadPagesAllowedForViewport = typeof layoutDiagnostics?.spreadPagesAllowedForViewport === 'boolean'
            ? layoutDiagnostics.spreadPagesAllowedForViewport
            : null;
        const layoutWritingMode = typeof layoutDiagnostics?.writingMode === 'string'
            ? layoutDiagnostics.writingMode
            : (typeof chunkLayoutMetrics?.writingMode === 'string' ? chunkLayoutMetrics.writingMode : null);
        const layoutViewportWidth = Number.isFinite(chunkLayoutMetrics?.viewportWidth)
            ? chunkLayoutMetrics.viewportWidth
            : null;
        const layoutViewportHeight = Number.isFinite(chunkLayoutMetrics?.viewportHeight)
            ? chunkLayoutMetrics.viewportHeight
            : null;
        const layoutMeasuredGap = Number.isFinite(chunkLayoutMetrics?.gap)
            ? chunkLayoutMetrics.gap
            : null;
        const layoutMetricSize = Number.isFinite(chunkLayoutMetrics?.size)
            ? chunkLayoutMetrics.size
            : null;
        const layoutColumnInlineSize = Number.isFinite(chunkLayoutMetrics?.columnInlineSize)
            ? chunkLayoutMetrics.columnInlineSize
            : null;
        const layoutCurrentChunkClientWidth = Number.isFinite(layoutDiagnostics?.currentChunkClientWidth)
            ? layoutDiagnostics.currentChunkClientWidth
            : null;
        const layoutCurrentChunkClientHeight = Number.isFinite(layoutDiagnostics?.currentChunkClientHeight)
            ? layoutDiagnostics.currentChunkClientHeight
            : null;
        const layoutCurrentChunkScrollWidth = Number.isFinite(layoutDiagnostics?.currentChunkScrollWidth)
            ? layoutDiagnostics.currentChunkScrollWidth
            : null;
        const layoutCurrentChunkScrollHeight = Number.isFinite(layoutDiagnostics?.currentChunkScrollHeight)
            ? layoutDiagnostics.currentChunkScrollHeight
            : null;
        const layoutCurrentChunkOverflow = typeof layoutDiagnostics?.currentChunkOverflow === 'boolean'
            ? layoutDiagnostics.currentChunkOverflow
            : null;
        const shouldLogZeroLayout =
            layoutLiveRootExists === true
            && layoutLiveCurrentPageExists === true
            && layoutLiveCurrentChunkExists === true
            && (
                layoutLiveRootRectWidth === 0
                || layoutLiveRootRectHeight === 0
                || layoutLiveCurrentPageRectWidth === 0
                || layoutLiveCurrentPageRectHeight === 0
                || layoutLiveCurrentChunkRectWidth === 0
                || layoutLiveCurrentChunkRectHeight === 0
            );
        if (shouldLogZeroLayout) {
            try {
                const liveRoot = view?.document?.getElementById?.('reader-content') ?? null;
                const liveRootParent = liveRoot?.parentElement ?? null;
                const liveRootParentRect = liveRootParent?.getBoundingClientRect?.() ?? null;
                const rootNode = liveRoot?.getRootNode?.() ?? null;
                const liveRootHost = rootNode instanceof ShadowRoot ? rootNode.host : null;
                const liveRootHostRect = liveRootHost?.getBoundingClientRect?.() ?? null;
                logFix('page-turn-probe-zero-layout', {
                    pageURL: window.location.href,
                    attempt: Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0,
                    loadEBookLastState: globalThis.manabiLoadEBookLastState ?? null,
                    liveRootTagName: liveRoot?.tagName?.toLowerCase?.() ?? null,
                    liveRootClassName: liveRoot?.className ?? null,
                    liveRootDisplay: liveRoot ? globalThis.getComputedStyle?.(liveRoot)?.display ?? null : null,
                    liveRootVisibility: liveRoot ? globalThis.getComputedStyle?.(liveRoot)?.visibility ?? null : null,
                    liveRootParentTagName: liveRootParent?.tagName?.toLowerCase?.() ?? null,
                    liveRootParentClassName: liveRootParent?.className ?? null,
                    liveRootParentRectWidth: liveRootParentRect ? Math.round(liveRootParentRect.width) : null,
                    liveRootParentRectHeight: liveRootParentRect ? Math.round(liveRootParentRect.height) : null,
                    liveRootParentDisplay: liveRootParent ? globalThis.getComputedStyle?.(liveRootParent)?.display ?? null : null,
                    liveRootParentVisibility: liveRootParent ? globalThis.getComputedStyle?.(liveRootParent)?.visibility ?? null : null,
                    liveRootHostTagName: liveRootHost?.tagName?.toLowerCase?.() ?? null,
                    liveRootHostClassName: liveRootHost?.className ?? null,
                    liveRootHostRectWidth: liveRootHostRect ? Math.round(liveRootHostRect.width) : null,
                    liveRootHostRectHeight: liveRootHostRect ? Math.round(liveRootHostRect.height) : null,
                    liveRootHostDisplay: liveRootHost ? globalThis.getComputedStyle?.(liveRootHost)?.display ?? null : null,
                    liveRootHostVisibility: liveRootHost ? globalThis.getComputedStyle?.(liveRootHost)?.visibility ?? null : null,
                    layoutLiveRootRectWidth,
                    layoutLiveRootRectHeight,
                    layoutLiveCurrentPageRectWidth,
                    layoutLiveCurrentPageRectHeight,
                    layoutLiveCurrentChunkRectWidth,
                    layoutLiveCurrentChunkRectHeight,
                });
            } catch (_error) {}
        }
        const liveDoc = view?.document ?? null;
        const liveRoot = liveDoc
            ? (liveDoc.getElementById?.('reader-content') || liveDoc.body || null)
            : null;
        const livePageRoot = liveRoot?.querySelector?.('.manabi-page-root') || null;
        const allLivePages = Array.from(liveRoot?.querySelectorAll?.('.manabi-page') || []);
        const sameDocumentDatasetPageIndex = Number.parseInt(
            livePageRoot?.dataset?.manabiCurrentPageIndex ?? '',
            10
        );
        const sameDocumentPageIndex = Number.isFinite(sameDocumentDatasetPageIndex)
            ? Math.max(0, sameDocumentDatasetPageIndex)
            : null;
        const sameDocumentPageCount = allLivePages.length > 0 ? allLivePages.length : null;
        const rendererReportedPage = typeof renderer?.page === 'function'
            ? await renderer.page()
            : layoutCurrentPageIndex;
        const rendererReportedPageCount = typeof renderer?.pages === 'function'
            ? await renderer.pages()
            : layoutPageCount;
        const page = sameDocumentPageIndex ?? rendererReportedPage;
        const pageCount = sameDocumentPageCount ?? rendererReportedPageCount;
        const currentSectionIndex = Number.isFinite(renderer?.currentIndex) ? renderer.currentIndex : null;
        const currentSectionHref = currentSectionIndex != null
            ? renderer?.sections?.[currentSectionIndex]?.href
                ?? renderer?.sections?.[currentSectionIndex]?.url
                ?? null
            : null;
        const atSectionStart = typeof renderer?.isAtSectionStart === 'function'
            ? await renderer.isAtSectionStart()
            : null;
        const atSectionEnd = typeof renderer?.isAtSectionEnd === 'function'
            ? await renderer.isAtSectionEnd()
            : null;
        const hasPrevSection = typeof renderer?.getHasPrevSection === 'function'
            ? !!renderer.getHasPrevSection()
            : false;
        const hasNextSection = typeof renderer?.getHasNextSection === 'function'
            ? !!renderer.getHasNextSection()
            : false;
        const canBackward = atSectionStart === true
            ? hasPrevSection
            : (Number.isFinite(page) ? page > 0 || hasPrevSection : false);
        const canForward = atSectionEnd === true
            ? hasNextSection
            : (Number.isFinite(page) && Number.isFinite(pageCount) ? (page + 1) < pageCount || hasNextSection : false);
        const bodyStyle = globalThis.getComputedStyle?.(globalThis.document?.body ?? null);
        const computedFontSizeCSS = bodyStyle?.fontSize ?? null;
        const pageIndex = Number.isFinite(page) ? Math.max(0, page) : 0;
        const allLiveChunks = Array.from(liveRoot?.querySelectorAll?.('.manabi-page-column-chunk') || []);
        const closestPageForElement = element => element?.closest?.('.manabi-page') || null;
        const closestChunkForElement = element => element?.closest?.('.manabi-page-column-chunk') || null;
        const viewportRect = (() => {
            try {
                return document.getElementById('reader-stage')?.getBoundingClientRect?.()
                    || document.getElementById('manabi-same-document-viewport')?.getBoundingClientRect?.()
                    || null;
            } catch {
                return null;
            }
        })();
        const viewportCenterX = viewportRect ? Math.round(viewportRect.left + viewportRect.width / 2) : null;
        const viewportCenterY = viewportRect ? Math.round(viewportRect.top + viewportRect.height / 2) : null;
        const viewportCenterElement = (viewportCenterX != null && viewportCenterY != null && liveDoc?.elementFromPoint)
            ? liveDoc.elementFromPoint(viewportCenterX, viewportCenterY)
            : null;
        const viewportCenterChunk = closestChunkForElement(viewportCenterElement)
            || allLiveChunks.find(node => {
                const rect = node?.getBoundingClientRect?.();
                return rect
                    && rect.width > 0
                    && rect.height > 0
                    && viewportCenterX != null
                    && viewportCenterY != null
                    && viewportCenterX >= rect.left
                    && viewportCenterX <= rect.right
                    && viewportCenterY >= rect.top
                    && viewportCenterY <= rect.bottom;
            })
            || null;
        const liveChunk = viewportCenterChunk
            || liveRoot?.querySelector?.('.manabi-page .manabi-page-column-chunk')
            || liveRoot?.querySelector?.('.manabi-page-column-chunk')
            || null;
        const viewportCenterPage = closestPageForElement(viewportCenterElement)
            || closestPageForElement(viewportCenterChunk)
            || allLivePages.find(node => {
                const rect = node?.getBoundingClientRect?.();
                return rect
                    && rect.width > 0
                    && rect.height > 0
                    && viewportCenterX != null
                    && viewportCenterY != null
                    && viewportCenterX >= rect.left
                    && viewportCenterX <= rect.right
                    && viewportCenterY >= rect.top
                    && viewportCenterY <= rect.bottom;
            })
            || null;
        const livePage = viewportCenterPage
            || closestPageForElement(liveChunk)
            || liveRoot?.querySelector?.('.manabi-page')
            || null;
        const layoutLiveCurrentPageIndex = livePage ? allLivePages.indexOf(livePage) : -1;
        const layoutLiveCurrentChunkPageIndex = liveChunk
            ? allLivePages.findIndex(pageNode => pageNode?.contains?.(liveChunk))
            : -1;
        const layoutViewportCenterChunkPageIndex = viewportCenterChunk
            ? allLivePages.findIndex(pageNode => pageNode?.contains?.(viewportCenterChunk))
            : -1;
        const visibleRangeFor = index => {
            try {
                return typeof sectionLayoutController?.visibleSourceRange === 'function'
                    ? sectionLayoutController.visibleSourceRange(index)
                    : null;
            } catch {
                return null;
            }
        };
        const sampleForRange = range => {
            try {
                const text = range?.toString?.() ?? '';
                const normalized = String(text).replace(/\s+/g, ' ').trim();
                return normalized ? normalized.slice(0, 180) : null;
            } catch {
                return null;
            }
        };
        const currentPageTextSample = sampleForRange(visibleRangeFor(pageIndex));
        const nextPageTextSample = Number.isFinite(pageCount) && pageIndex + 1 < pageCount
            ? sampleForRange(visibleRangeFor(pageIndex + 1))
            : null;
        const pageTargets = Array.isArray(globalThis.navHUD?.pageTargets) ? globalThis.navHUD.pageTargets : [];
        const normalizedPageTarget = Number.isFinite(pageIndex) && pageIndex >= 0
            ? (pageTargets[pageIndex] ?? null)
            : null;
        const normalizedTotalPages = Number.isFinite(pageCount) && pageCount > 0
            ? pageCount
            : (pageTargets.length > 0 ? pageTargets.length : null);
        const normalizedDisplayLabel = value => {
            if (typeof value !== 'string') return null;
            const trimmed = value.trim();
            return trimmed.length > 0 ? trimmed : null;
        };
        const currentPageDisplayLabel = (() => {
            const latestLabel = normalizedDisplayLabel(globalThis.navHUD?.latestPrimaryLabel);
            if (latestLabel) {
                return latestLabel;
            }
            if (typeof globalThis.navHUD?.getPrimaryDisplayLabel === 'function'
                && Number.isFinite(pageIndex)
                && pageIndex >= 0) {
                const computedLabel = normalizedDisplayLabel(globalThis.navHUD.getPrimaryDisplayLabel({
                    pageItem: normalizedPageTarget,
                    pageNumber: pageIndex + 1,
                    pageCount: normalizedTotalPages,
                    location: normalizedTotalPages ? { current: pageIndex, total: normalizedTotalPages } : null,
                }));
                if (computedLabel) {
                    return computedLabel;
                }
            }
            if (Number.isFinite(pageIndex) && pageIndex >= 0) {
                if (typeof normalizedTotalPages === 'number' && normalizedTotalPages > 0) {
                    return `Page ${pageIndex + 1} of ${normalizedTotalPages}`;
                }
                return `Page ${pageIndex + 1}`;
            }
            return null;
        })();
        const currentPhysicalPageLabel = (() => {
            const diagnosticLabel = normalizedDisplayLabel(globalThis.navHUD?.lastPrimaryLabelDiagnostics?.pageItemLabel);
            if (diagnosticLabel) {
                return diagnosticLabel;
            }
            return normalizedDisplayLabel(normalizedPageTarget?.label);
        })();
        const livePageIndex = Number.isFinite(layoutLiveCurrentPageIndex) && layoutLiveCurrentPageIndex >= 0 ? layoutLiveCurrentPageIndex : null;
        const liveChunkPageIndex = Number.isFinite(layoutLiveCurrentChunkPageIndex) && layoutLiveCurrentChunkPageIndex >= 0 ? layoutLiveCurrentChunkPageIndex : null;
        const viewportCenterChunkPageIndex = Number.isFinite(layoutViewportCenterChunkPageIndex) && layoutViewportCenterChunkPageIndex >= 0 ? layoutViewportCenterChunkPageIndex : null;
        const loadEBookStarted = !!globalThis.manabiLoadEBookStarted;
        const loadEBookReady = !!globalThis.manabiLoadEBookReady;
        const loadEBookAttemptCount = Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0;
        const loadEBookStartedAt = Number(globalThis.manabiLoadEBookStartedAt || 0) || 0;
        const loadEBookStartAgeMs = loadEBookStartedAt > 0 ? Math.max(0, Date.now() - loadEBookStartedAt) : null;
        const loadEBookLastState = globalThis.manabiLoadEBookLastState ?? null;
        const previousLoadEBookState = globalThis.manabiPreviousLoadEBookLastState ?? null;
        const previousLoadEBookError = globalThis.manabiPreviousLoadEBookError ?? null;
        const sameDocumentHostTurnPhase = globalThis.manabiSameDocumentHostTurnDiagnostics?.phase ?? null;
        const sameDocumentHostTurnDirection = globalThis.manabiSameDocumentHostTurnDiagnostics?.direction ?? null;
        const sameDocumentHostTurnCurrentPageIndex = Number.isFinite(globalThis.manabiSameDocumentHostTurnDiagnostics?.currentPageIndex)
            ? globalThis.manabiSameDocumentHostTurnDiagnostics.currentPageIndex
            : null;
        const sameDocumentHostTurnTargetPageIndex = Number.isFinite(globalThis.manabiSameDocumentHostTurnDiagnostics?.targetPageIndex)
            ? globalThis.manabiSameDocumentHostTurnDiagnostics.targetPageIndex
            : null;
        const sameDocumentHostTurnPageCount = Number.isFinite(globalThis.manabiSameDocumentHostTurnDiagnostics?.pageCount)
            ? globalThis.manabiSameDocumentHostTurnDiagnostics.pageCount
            : null;
        const sameDocumentHostTurnDatasetCurrentPageIndex = Number.isFinite(globalThis.manabiSameDocumentHostTurnDiagnostics?.datasetCurrentPageIndex)
            ? globalThis.manabiSameDocumentHostTurnDiagnostics.datasetCurrentPageIndex
            : null;
        const sameDocumentHostTurnResult = typeof globalThis.manabiSameDocumentHostTurnDiagnostics?.result === 'string'
            ? globalThis.manabiSameDocumentHostTurnDiagnostics.result
            : null;
        const shouldReportPreviousLoadIssue =
            !view &&
            !renderer &&
            !loadEBookReady &&
            loadEBookLastState !== 'open-resolved' &&
            loadEBookLastState !== 'posting-loaded';
        return {
            hasView: !!view,
            hasRenderer: !!renderer,
            canNext: typeof view?.next === 'function',
            canPrev: typeof view?.prev === 'function',
            canForward: canForward || (Number.isFinite(page) && Number.isFinite(pageCount) ? page + 1 < pageCount : false),
            canBackward: canBackward || (Number.isFinite(page) ? page > 0 : false),
            hasSectionLayoutController: !!sectionLayoutController,
            bookDirection: globalThis.reader?.book?.dir ?? view?.book?.dir ?? null,
            isRightToLeft: !!(
                globalThis.manabiGetWritingDirectionSnapshot?.()?.rtl
                ?? ((globalThis.reader?.book?.dir ?? view?.book?.dir ?? '').toLowerCase() === 'rtl')
            ),
            isVertical: globalThis.manabiGetWritingDirectionSnapshot?.()?.vertical === true,
            isVerticalRightToLeft: globalThis.manabiGetWritingDirectionSnapshot?.()?.verticalRTL === true,
            currentSectionIndex,
            currentSectionHref,
            currentPage: Number.isFinite(page) ? page : null,
            pageCount: Number.isFinite(pageCount) ? pageCount : null,
            layoutPageRecordCount,
            layoutLiveRootExists,
            layoutLiveRootClassName,
            layoutLiveRootChildCount,
            layoutLiveRootRectWidth,
            layoutLiveRootRectHeight,
            layoutLiveCurrentPageExists,
            layoutLiveCurrentPageClassName,
            layoutLiveCurrentPageRectWidth,
            layoutLiveCurrentPageRectHeight,
            layoutLiveCurrentPageContainsChunkBody,
            layoutLiveCurrentChunkExists,
            layoutLiveCurrentChunkTagName,
            layoutLiveCurrentChunkClassName,
            layoutLiveCurrentChunkDisplay,
            layoutLiveCurrentChunkPosition,
            layoutLiveCurrentChunkFlex,
            layoutLiveCurrentChunkRectWidth,
            layoutLiveCurrentChunkRectHeight,
            layoutLiveCurrentChunkInnerHTMLLength,
            layoutLiveCurrentChunkContainsChunkBody,
            layoutLiveCurrentChunkChildCount,
            layoutLiveCurrentChunkTextLength,
            layoutCurrentChunkBodyChildCount,
            layoutCurrentChunkBodyTextLength,
            layoutCurrentChunkBodyDisplay,
            layoutCurrentChunkBodyPosition,
            layoutCurrentChunkBodyFlex,
            layoutColumnCount,
            layoutCurrentPageIndex,
            layoutCurrentPageChunkCount,
            layoutMaxPageChunkCount,
            layoutUnitCount,
            layoutActiveBuildPageIndex,
            layoutComplete,
            layoutSpreadCandidateDetected,
            layoutVisibleUnitKind,
            layoutVisibleUnitAxis,
            layoutVisiblePageCount,
            layoutCurrentUnitIndex,
            layoutLeadingPageIndex,
            layoutTrailingPageIndex,
            layoutHasLeadingSingleton,
            layoutHasTrailingSingleton,
            layoutMultiUnitActive,
            layoutSpreadPagesAllowedForViewport,
            layoutWritingMode,
            layoutViewportWidth,
            layoutViewportHeight,
            layoutMeasuredGap,
            layoutMetricSize,
            layoutColumnInlineSize,
            layoutCurrentChunkClientWidth,
            layoutCurrentChunkClientHeight,
            layoutCurrentChunkScrollWidth,
            layoutCurrentChunkScrollHeight,
            layoutCurrentChunkOverflow,
            computedFontSizeCSS,
            currentPageTextSample,
            nextPageTextSample,
            currentPageDisplayLabel,
            currentPhysicalPageLabel,
            progressScrubberVisible: sliderVisibility,
            progressScrubberActive: !!this.#progressScrubState,
            livePageIndex,
            liveChunkPageIndex,
            viewportCenterChunkPageIndex,
            loadEBookStarted,
            loadEBookReady,
            loadEBookAttemptCount,
            loadEBookStartAgeMs,
            loadEBookLastState,
            sameDocumentHostTurnPhase,
            sameDocumentHostTurnDirection,
            sameDocumentHostTurnCurrentPageIndex,
            sameDocumentHostTurnTargetPageIndex,
            sameDocumentHostTurnPageCount,
            sameDocumentHostTurnDatasetCurrentPageIndex,
            sameDocumentHostTurnResult,
            probeError: shouldReportPreviousLoadIssue
                ? (previousLoadEBookError ?? previousLoadEBookState ?? null)
                : null,
        };
    } catch (error) {
        const loadEBookStarted = !!globalThis.manabiLoadEBookStarted;
        const loadEBookReady = !!globalThis.manabiLoadEBookReady;
        const loadEBookAttemptCount = Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0;
        const loadEBookStartedAt = Number(globalThis.manabiLoadEBookStartedAt || 0) || 0;
        const loadEBookStartAgeMs = loadEBookStartedAt > 0 ? Math.max(0, Date.now() - loadEBookStartedAt) : null;
        const loadEBookLastState = globalThis.manabiLoadEBookLastState ?? null;
        const previousLoadEBookState = globalThis.manabiPreviousLoadEBookLastState ?? null;
        const previousLoadEBookError = globalThis.manabiPreviousLoadEBookError ?? null;
        const hasView = !!globalThis.reader?.view;
        const hasRenderer = !!globalThis.reader?.view?.renderer;
        const shouldReportPreviousLoadIssue =
            !hasView &&
            !hasRenderer &&
            !loadEBookReady &&
            loadEBookLastState !== 'open-resolved' &&
            loadEBookLastState !== 'posting-loaded';
        return {
            hasView,
            hasRenderer,
            canNext: typeof globalThis.reader?.view?.next === 'function',
            canPrev: typeof globalThis.reader?.view?.prev === 'function',
            canForward: false,
            canBackward: false,
            hasSectionLayoutController: !!(
                globalThis.reader?.view?.document?.defaultView?.manabiEbookSectionLayoutController
                ?? globalThis.manabiEbookSectionLayoutController
            ),
            bookDirection: globalThis.reader?.book?.dir ?? globalThis.reader?.view?.book?.dir ?? null,
            isRightToLeft: !!(
                globalThis.manabiGetWritingDirectionSnapshot?.()?.rtl
                ?? ((globalThis.reader?.book?.dir ?? globalThis.reader?.view?.book?.dir ?? '').toLowerCase() === 'rtl')
            ),
            isVertical: globalThis.manabiGetWritingDirectionSnapshot?.()?.vertical === true,
            isVerticalRightToLeft: globalThis.manabiGetWritingDirectionSnapshot?.()?.verticalRTL === true,
            currentSectionIndex: Number.isFinite(globalThis.reader?.view?.renderer?.currentIndex)
                ? globalThis.reader.view.renderer.currentIndex
                : null,
            currentSectionHref: Number.isFinite(globalThis.reader?.view?.renderer?.currentIndex)
                ? (
                    globalThis.reader?.view?.renderer?.sections?.[globalThis.reader.view.renderer.currentIndex]?.href
                    ?? globalThis.reader?.view?.renderer?.sections?.[globalThis.reader.view.renderer.currentIndex]?.url
                    ?? null
                )
                : null,
            currentPage: null,
            pageCount: null,
            layoutPageRecordCount: null,
            layoutLiveRootExists: null,
            layoutLiveRootClassName: null,
            layoutLiveRootChildCount: null,
            layoutLiveRootRectWidth: null,
            layoutLiveRootRectHeight: null,
            layoutLiveCurrentPageExists: null,
            layoutLiveCurrentPageClassName: null,
            layoutLiveCurrentPageRectWidth: null,
            layoutLiveCurrentPageRectHeight: null,
            layoutLiveCurrentChunkExists: null,
            layoutLiveCurrentChunkClassName: null,
            layoutLiveCurrentChunkRectWidth: null,
            layoutLiveCurrentChunkRectHeight: null,
            layoutColumnCount: null,
            layoutCurrentPageIndex: null,
            layoutCurrentPageChunkCount: null,
            layoutMaxPageChunkCount: null,
            layoutUnitCount: null,
            layoutActiveBuildPageIndex: null,
            layoutComplete: null,
            layoutSpreadCandidateDetected: null,
            layoutVisibleUnitKind: null,
            layoutVisibleUnitAxis: null,
            layoutVisiblePageCount: null,
            layoutCurrentUnitIndex: null,
            layoutLeadingPageIndex: null,
            layoutTrailingPageIndex: null,
            layoutMultiUnitActive: null,
            layoutSpreadPagesAllowedForViewport: null,
            layoutWritingMode: null,
            layoutViewportWidth: null,
            layoutViewportHeight: null,
            layoutMetricSize: null,
            layoutColumnInlineSize: null,
            layoutCurrentChunkClientWidth: null,
            layoutCurrentChunkClientHeight: null,
            layoutCurrentChunkScrollWidth: null,
            layoutCurrentChunkScrollHeight: null,
            layoutCurrentChunkOverflow: null,
            computedFontSizeCSS: globalThis.getComputedStyle?.(globalThis.document?.body ?? null)?.fontSize ?? null,
            currentPageTextSample: null,
            nextPageTextSample: null,
            livePageIndex: null,
            liveChunkPageIndex: null,
            viewportCenterChunkPageIndex: null,
            loadEBookStarted,
            loadEBookReady,
            loadEBookAttemptCount,
            loadEBookStartAgeMs,
            loadEBookLastState,
            sameDocumentHostTurnPhase: null,
            sameDocumentHostTurnDirection: null,
            sameDocumentHostTurnCurrentPageIndex: null,
            sameDocumentHostTurnTargetPageIndex: null,
            sameDocumentHostTurnPageCount: null,
            sameDocumentHostTurnDatasetCurrentPageIndex: null,
            sameDocumentHostTurnResult: null,
            probeError: shouldReportPreviousLoadIssue
                ? (previousLoadEBookError ?? previousLoadEBookState ?? String(error))
                : String(error),
        };
    }
};

window.manabiGetPageTurnProbeSnapshotJSON = async () => {
    try {
        return JSON.stringify(await window.manabiGetPageTurnProbeSnapshot());
    } catch (error) {
        return JSON.stringify({
            hasView: !!globalThis.reader?.view,
            hasRenderer: !!globalThis.reader?.view?.renderer,
            canNext: typeof globalThis.reader?.view?.next === 'function',
            canPrev: typeof globalThis.reader?.view?.prev === 'function',
            canForward: false,
            canBackward: false,
            hasSectionLayoutController: !!(
                globalThis.reader?.view?.document?.defaultView?.manabiEbookSectionLayoutController
                ?? globalThis.manabiEbookSectionLayoutController
            ),
            bookDirection: globalThis.reader?.book?.dir ?? globalThis.reader?.view?.book?.dir ?? null,
            isRightToLeft: !!(
                globalThis.manabiGetWritingDirectionSnapshot?.()?.rtl
                ?? ((globalThis.reader?.book?.dir ?? globalThis.reader?.view?.book?.dir ?? '').toLowerCase() === 'rtl')
            ),
            isVertical: globalThis.manabiGetWritingDirectionSnapshot?.()?.vertical === true,
            isVerticalRightToLeft: globalThis.manabiGetWritingDirectionSnapshot?.()?.verticalRTL === true,
            currentSectionIndex: Number.isFinite(globalThis.reader?.view?.renderer?.currentIndex)
                ? globalThis.reader.view.renderer.currentIndex
                : null,
            currentSectionHref: Number.isFinite(globalThis.reader?.view?.renderer?.currentIndex)
                ? (
                    globalThis.reader?.view?.renderer?.sections?.[globalThis.reader.view.renderer.currentIndex]?.href
                    ?? globalThis.reader?.view?.renderer?.sections?.[globalThis.reader.view.renderer.currentIndex]?.url
                    ?? null
                )
                : null,
            currentPage: null,
            pageCount: null,
            computedFontSizeCSS: globalThis.getComputedStyle?.(globalThis.document?.body ?? null)?.fontSize ?? null,
            currentPageTextSample: null,
            nextPageTextSample: null,
            livePageIndex: null,
            liveChunkPageIndex: null,
            viewportCenterChunkPageIndex: null,
            probeError: `probe-json-wrapper:${String(error)}`,
        });
    }
};

window.loadEBook = ({
    url,
    layoutMode,
}) => {
    const priorAttemptCount = Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0;
    if (priorAttemptCount > 0 && globalThis.manabiLoadEBookReady !== true) {
        globalThis.manabiPreviousLoadEBookLastState =
            globalThis.manabiLoadEBookLastState
            ?? `restart-before-ready:attempt-${priorAttemptCount}`;
        globalThis.manabiPreviousLoadEBookError =
            globalThis.manabiPreviousLoadEBookError
            ?? globalThis.manabiLoadEBookLastState
            ?? `restart-before-ready:attempt-${priorAttemptCount}`;
    }
    globalThis.manabiLoadEBookLastState = 'called';
    globalThis.manabiLoadEBookStarted = true;
    globalThis.manabiLoadEBookStartedAt = Date.now();
    globalThis.manabiLoadEBookReady = false;
    globalThis.manabiLoadEBookAttemptCount = (Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0) + 1;
    const loadAttemptNumber = globalThis.manabiLoadEBookAttemptCount;
    logFix('loadEBook:called', {
        hasURL: !!url,
        attempt: loadAttemptNumber,
        layoutMode: layoutMode ?? null,
        pageURL: window.location.href,
    });
    let reader = new Reader()
    globalThis.reader = reader
    globalThis.manabiLoadEBookLastState = 'reader-created';
    logFix('loadEBook:reader-created', {
        hasReader: !!globalThis.reader,
        hasView: !!globalThis.reader?.view,
    });
    setTimeout(() => logReaderBootstrapState('loadEBook:delayed-state:1s'), 1000);
    setTimeout(() => logReaderBootstrapState('loadEBook:delayed-state:3s'), 3000);
    setTimeout(() => logReaderBootstrapState('loadEBook:delayed-state:8s'), 8000);
    if (pendingHideNavigationState !== null) {
        reader.setHideNavigationDueToScroll(pendingHideNavigationState);
        pendingHideNavigationState = null;
    }

    window.cacheWarmer = new CacheWarmer()

    if (url) {
    const source = makeNativeSource(url)
    window.bookSource = source
    if (layoutMode) {
    window.initialLayoutMode = layoutMode
    }
    const isCurrentAttempt = () =>
    (Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0) === loadAttemptNumber
    && globalThis.reader === reader;
    setTimeout(() => {
    const currentAttempt = Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0;
    const hasRendererNow = !!globalThis.reader?.view?.renderer;
    if (globalThis.manabiLoadEBookReady || hasRendererNow || currentAttempt !== loadAttemptNumber) {
    return;
    }
    globalThis.manabiPreviousLoadEBookLastState = globalThis.manabiLoadEBookLastState ?? 'open-watchdog-timeout';
    globalThis.manabiPreviousLoadEBookError = 'open-watchdog-timeout';
    globalThis.manabiLoadEBookStarted = false;
    globalThis.manabiLoadEBookReady = false;
    globalThis.manabiLoadEBookLastState = 'open-watchdog-timeout';
    try { globalThis.reader?.close?.(); } catch (_error) {}
    try { globalThis.reader?.view?.close?.(); } catch (_error) {}
    globalThis.reader = null;
    logFix('loadEBook:watchdog-timeout', {
    attempt: loadAttemptNumber,
    pageURL: window.location.href,
    retrying: loadAttemptNumber < 4,
    });
    if (loadAttemptNumber < 4) {
    setTimeout(() => {
    if ((Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0) === loadAttemptNumber && typeof window.loadEBook === 'function') {
    window.loadEBook({ url, layoutMode });
    }
    }, 0);
    }
    }, 6000);
    globalThis.manabiLoadEBookLastState = 'open-requested';
    Promise.resolve(reader.open(source))
    .then(async () => {
    if (!isCurrentAttempt()) {
    logFix('loadEBook:open-resolved-stale-attempt', {
    attempt: loadAttemptNumber,
    activeAttempt: Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0,
    localHasView: !!reader?.view,
    localHasRenderer: !!reader?.view?.renderer,
    globalHasView: !!globalThis.reader?.view,
    globalHasRenderer: !!globalThis.reader?.view?.renderer,
    });
    return;
    }
    globalThis.manabiLoadEBookReady = true;
    globalThis.manabiLoadEBookLastState = 'open-resolved';
    logFix('loadEBook:open-resolved', {
    hasReader: !!reader,
    hasView: !!reader?.view,
    hasRenderer: !!reader?.view?.renderer,
    });
    try {
    const currentDoc = reader?.view?.document
    if (currentDoc) {
    await globalThis.manabiEnsureCustomFonts?.(currentDoc)
    }
    } catch (_error) {
    // best effort
    }
    })
    .then(async () => {
    if (!isCurrentAttempt()) {
    logFix('loadEBook:posting-loaded-stale-attempt', {
    attempt: loadAttemptNumber,
    activeAttempt: Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0,
    localHasView: !!reader?.view,
    localHasRenderer: !!reader?.view?.renderer,
    globalHasView: !!globalThis.reader?.view,
    globalHasRenderer: !!globalThis.reader?.view?.renderer,
    });
    return;
    }
    globalThis.manabiLoadEBookLastState = 'posting-loaded';
    const loadedProbe = {
    hasView: !!reader?.view,
    hasRenderer: !!reader?.view?.renderer,
    canForward: !!reader?.view?.renderer?.getHasNextSection?.(),
    canBackward: !!reader?.view?.renderer?.getHasPrevSection?.(),
    currentPage: typeof reader?.view?.renderer?.page === 'function'
      ? await Promise.resolve(reader.view.renderer.page()).catch(() => null)
      : null,
    pageCount: typeof reader?.view?.renderer?.pages === 'function'
      ? await Promise.resolve(reader.view.renderer.pages()).catch(() => null)
      : null,
    loadEBookLastState: globalThis.manabiLoadEBookLastState ?? null,
    loadEBookReady: true,
    probeError: null,
    };
    logFix('loadEBook:posting-loaded', {
    hasReader: !!reader,
    hasView: !!reader?.view,
    hasRenderer: !!reader?.view?.renderer,
    probeHasView: loadedProbe?.hasView ?? null,
    probeHasRenderer: loadedProbe?.hasRenderer ?? null,
    });
    window.webkit.messageHandlers.ebookViewerLoaded.postMessage({
    probe: loadedProbe,
    })
    })
    .catch(error => {
    if (!isCurrentAttempt()) {
    logFix('loadEBook:open-error-stale-attempt', {
    attempt: loadAttemptNumber,
    activeAttempt: Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0,
    message: error?.message ?? String(error),
    });
    return;
    }
    globalThis.manabiPreviousLoadEBookLastState = globalThis.manabiLoadEBookLastState ?? 'open-error';
    globalThis.manabiPreviousLoadEBookError = String(error);
    globalThis.manabiLoadEBookStarted = false;
    globalThis.manabiLoadEBookReady = false;
    globalThis.manabiLoadEBookLastState = 'open-error:' + String(error);
    try {
    postReaderOnError({
    message: sanitizeErrorValue(error?.message) ?? 'loadEBook failed',
    source: sanitizeErrorValue(url),
    lineno: null,
    colno: null,
    error: sanitizeErrorValue(error?.stack ?? error),
    })
    } catch (_reportError) {
    // best effort
    }
    throw error
    })
    }
    //.catch(e => console.error(e))
}

const scheduleAutomaticInitialBookLoad = () => {
    let parsedURL = null;
    try {
        parsedURL = new URL(window.location.href);
    } catch (_error) {
        return;
    }
    if (parsedURL.protocol !== 'ebook:' || !parsedURL.pathname.startsWith('/load/')) {
        return;
    }
    const start = (attempt = 0) => {
        if (globalThis.manabiLoadEBookStarted) {
            return;
        }
        if (typeof window.loadEBook !== 'function') {
            if (attempt < 10) {
                setTimeout(() => start(attempt + 1), Math.min(1000, 100 * (attempt + 1)));
            }
            return;
        }
        logFix('loadEBook:auto-bootstrap', {
            attempt,
            pageURL: window.location.href,
        });
        window.loadEBook({
            url: window.location.href,
            layoutMode: globalThis.window.initialLayoutMode ?? 'paginated',
        });
    };
    setTimeout(() => start(0), 0);
};

scheduleAutomaticInitialBookLoad();

window.loadLastPosition = async ({
    cfi,
    fractionalCompletion,
}) => {
    // On the same-document renderer path, section-load promises can remain in flight
    // longer than the shell contract expects. Mark restore as active up front so
    // subsequent loads can emit progress/state updates instead of staying muted.
    globalThis.reader.hasLoadedLastPosition = true
    const parsedFraction = Number(fractionalCompletion)
    const hasFractionalCompletion = Number.isFinite(parsedFraction)
    const shouldRestoreFraction = hasFractionalCompletion && parsedFraction > 0
    const restoreFirstSection = async reason => {
        await globalThis.reader.view.renderer.firstSection()
        logFix('loadLastPosition:first-section', {
            reason,
            hasCFI: cfi.length > 0,
            hasFractionalCompletion,
            fractionalCompletion: hasFractionalCompletion ? parsedFraction : null,
        })
    }

    if (cfi.length > 0) {
        await globalThis.reader.view.goTo(cfi).catch(async e => {
            console.error(e)
            if (shouldRestoreFraction) {
                await globalThis.reader.view.goToFraction(parsedFraction)
                logFix('loadLastPosition:fraction-fallback', {
                    reason: 'cfi-error',
                    fractionalCompletion: parsedFraction,
                })
            } else {
                await restoreFirstSection('cfi-error')
            }
        })
    } else if (shouldRestoreFraction) {
        await globalThis.reader.view.goToFraction(parsedFraction)
        logFix('loadLastPosition:fraction', {
            fractionalCompletion: parsedFraction,
        })
    } else {
        await restoreFirstSection('no-saved-position')
    }

    // Seed page counts from persisted bake cache if available
    try {
        const key = getBookCacheKey();
        const handler = globalThis.webkit?.messageHandlers?.[MANABI_TRACKING_CACHE_HANDLER];
        if (key && handler?.postMessage) {
            handler.postMessage({ command: 'get', key: `${key}::pageCounts` });
        }
    } catch (error) {
        logFix('pagecount:restore:error', { error: String(error) });
    }

    // Don't overlap cache warming with initial page load
    if (window.bookSource) {
    await window.cacheWarmer.open(window.bookSource)
    }
}

globalThis.manabiResolveTrackingSizeCache = function (requestId, entries) {
    // Also reuse as page-count cache channel
    if (typeof requestId === 'string' && requestId.endsWith('::pageCounts')) {
        try {
            const map = new Map(entries ?? []);
            if (map.size > 0) {
                globalThis.cacheWarmerPageCounts = map;
                globalThis.cacheWarmerTotalPages = Array.from(map.values()).reduce((a, v) => a + (Number.isFinite(v) ? v : 0), 0);
                document.dispatchEvent(new CustomEvent('cachewarmer:pagecounts', {
                    detail: {
                        counts: Array.from(map.entries()),
                        total: globalThis.cacheWarmerTotalPages,
                        source: 'cache',
                    }
                }));
                logFix('pagecount:restored', { size: map.size, total: globalThis.cacheWarmerTotalPages });
            }
        } catch (error) {
            logFix('pagecount:restore:handler:error', { error: String(error) });
        }
    }
    if (typeof globalThis.manabiResolveTrackingSizeCacheOriginal === 'function') {
        return globalThis.manabiResolveTrackingSizeCacheOriginal(requestId, entries);
    }
}
if (!globalThis.manabiResolveTrackingSizeCacheOriginal) {
    globalThis.manabiResolveTrackingSizeCacheOriginal = globalThis.manabiResolveTrackingSizeCache;
}

window.refreshBookReadingProgress = async (articleReadingProgress) => {
    globalThis.reader.markedAsFinished = !!articleReadingProgress.articleMarkedAsFinished;
    await globalThis.reader.updateNavButtons();
}

window.nextSection = async () => {
    const btn = globalThis.reader?.buttons?.next;
    if (btn && btn.offsetParent !== null && getComputedStyle(btn).visibility !== 'hidden') {
        btn.click();
    } else {
        await globalThis.reader?.view?.renderer?.nextSection?.();
    }
}

logFix('module:posting-initialized', {
    pageURL: window.location.href,
    bodyReady: !!document.body,
});
globalThis.manabiEbookViewerInitializedAck = false;
globalThis.manabiMarkEbookViewerInitializedAck = () => {
    globalThis.manabiEbookViewerInitializedAck = true;
};

const postEbookViewerInitialized = (attempt = 0) => {
    if (globalThis.manabiEbookViewerInitializedAck) {
        return;
    }
    const handler = window.webkit?.messageHandlers?.ebookViewerInitialized;
    if (handler?.postMessage) {
        try {
            handler.postMessage({ attempt });
            logFix('ebookViewerInitialized:posted', { attempt });
        } catch (error) {
            logFix('ebookViewerInitialized:post:error', {
                attempt,
                error: String(error),
            });
        }
    } else {
        logFix('ebookViewerInitialized:handler:missing', { attempt });
    }
    if (!globalThis.manabiEbookViewerInitializedAck && attempt < 10) {
        setTimeout(() => postEbookViewerInitialized(attempt + 1), Math.min(1000, 100 * (attempt + 1)));
    }
};

postEbookViewerInitialized();
