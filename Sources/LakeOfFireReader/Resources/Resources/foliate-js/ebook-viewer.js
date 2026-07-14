import './view.js'
import {
createTOCView
} from './ui/tree.js'
import { NavigationHUD } from './ebook-viewer-nav.js'
import {
    ebookSegmentIdentity,
    ebookSegmentIdentifierAliases,
} from './ebook-segment-identity.js'
import {
    makeSyntheticRestoreLocator,
    parseSyntheticRestoreLocator,
} from './ebook-restore-coordination.js'
import {
    Overlayer
} from '../foliate-js/overlayer.js'

// Required for EPUB page clipping after iframe/chrome layout settles.
const MANABI_DISABLE_INITIAL_PAGINATOR_SETTLE = false;
const MANABI_ENABLE_DID_DISPLAY_POST_FRAME_SETTLE = false;
const MANABI_DISABLE_NAV_HIDDEN_LAYOUT_CLASSES = false;
const MANABI_DISABLE_DYNAMIC_CHROME_INSETS = true;
const MANABI_ENABLE_EBOOK_PAGE_TRACKING_BUTTONS = false;

const manabiReaderSegmentSelector = 'm-m';
const manabiReaderSurfaceSelector = 'm-t';
const manabiReaderSentenceSelector = 'm-s';
const manabiReaderSegmentTagNames = new Set(['m-m']);
const manabiReaderSurfaceTagNames = new Set(['m-t']);
const manabiReaderSentenceTagNames = new Set(['m-s']);
const manabiReaderTagName = element => element?.tagName?.toLowerCase?.() || '';
const manabiIsReaderSegmentElement = element => manabiReaderSegmentTagNames.has(manabiReaderTagName(element));
const manabiIsReaderSurfaceElement = element => manabiReaderSurfaceTagNames.has(manabiReaderTagName(element));
const manabiIsReaderSentenceElement = element => manabiReaderSentenceTagNames.has(manabiReaderTagName(element));
const manabiBlankNavigationMoveThreshold = 12;
const manabiSyntheticTouchMouseDistanceThreshold = 24;
const manabiEventScreenPoint = event => {
    const point = event?.changedTouches?.[0] ?? event?.touches?.[0] ?? event;
    if (!point) return null;
    return {
        x: point.screenX ?? point.clientX ?? null,
        y: point.screenY ?? point.clientY ?? null,
    };
};

const manabiSegmentSidecarParserVersion = 9;

const manabiSidecarTableValue = (table, index, fallback = null) => (
    Number.isInteger(index) && Array.isArray(table) && index >= 0 && index < table.length
        ? table[index]
        : fallback
);

const manabiSidecarTableArray = (tables, shortKey) => (
    Array.isArray(tables?.[shortKey])
        ? tables[shortKey]
        : []
);

const manabiExpandSegmentIDToken = (token) => {
    if (typeof token !== 'string' || token.length === 0) return null;
    if (token.startsWith('!')) return token.slice(1);
    if (token.startsWith('~')) return `_m${token.slice(1)}`;
    return `mnb-s${token}`;
};

const manabiExpandCompactSegmentMetadata = (segment, tables) => {
    const segmentHash = manabiSidecarTableValue(tables.h, segment?.[1], null);
    const sentenceID = manabiSidecarTableValue(tables.sid, segment?.[9], null);
    const paragraphID = manabiSidecarTableValue(tables.pid, segment?.[10], null);
    return {
        i: manabiExpandSegmentIDToken(segment?.[0]),
        h: segmentHash,
        sid: stableSegmentID(sentenceID, segmentHash),
        sentenceID,
        paragraphID,
        pid: paragraphID,
        j: manabiSidecarTableValue(tables.j, segment?.[2], []),
        n: manabiSidecarTableValue(tables.n, segment?.[3], []),
        s: manabiSidecarTableValue(tables.s, segment?.[4], null),
        ns: manabiSidecarTableValue(tables.ns, segment?.[5], null),
        p: manabiSidecarTableValue(tables.p, segment?.[6], null),
        l: segment?.[7],
        x: manabiSidecarTableValue(tables.x, segment?.[8], null),
    };
};

const manabiCompactSegmentMetadataTables = (payload) => ({
    h: manabiSidecarTableArray(payload.t, 'h'),
    j: manabiSidecarTableArray(payload.t, 'j'),
    n: manabiSidecarTableArray(payload.t, 'n'),
    s: manabiSidecarTableArray(payload.t, 's'),
    ns: manabiSidecarTableArray(payload.t, 'ns'),
    p: manabiSidecarTableArray(payload.t, 'p'),
    x: manabiSidecarTableArray(payload.t, 'x'),
    sid: manabiSidecarTableArray(payload.t, 'sid'),
    pid: manabiSidecarTableArray(payload.t, 'pid'),
});

class ManabiLazySegmentMetadataMap extends Map {
    constructor(payload) {
        super();
        this.compactSegments = [];
        this.tables = null;
        this.indexedSegmentCount = 0;
        this.materializedSegmentCount = 0;
        this.stableAliasesIndexed = false;
        if (payload?.v !== manabiSegmentSidecarParserVersion || !payload?.t || !Array.isArray(payload?.s)) {
            return;
        }
        this.compactSegments = payload.s;
        this.tables = manabiCompactSegmentMetadataTables(payload);
        for (let tupleIndex = 0; tupleIndex < payload.s.length; tupleIndex += 1) {
            const compactSegment = payload.s[tupleIndex];
            const elementID = manabiExpandSegmentIDToken(compactSegment?.[0]);
            if (!elementID) continue;
            const reference = tupleIndex + 1;
            super.set(elementID, reference);
            this.indexedSegmentCount += 1;
        }
    }

    ensureStableAliasesIndexed() {
        if (this.stableAliasesIndexed || !this.tables) return;
        this.stableAliasesIndexed = true;
        for (let tupleIndex = 0; tupleIndex < this.compactSegments.length; tupleIndex += 1) {
            const compactSegment = this.compactSegments[tupleIndex];
            const segmentHash = manabiSidecarTableValue(this.tables.h, compactSegment?.[1], null);
            const sentenceID = manabiSidecarTableValue(this.tables.sid, compactSegment?.[9], null);
            const stableID = stableSegmentID(sentenceID, segmentHash);
            if (stableID) super.set(stableID, tupleIndex + 1);
        }
    }

    get(identifier) {
        let value = super.get(identifier);
        if (value === undefined) {
            this.ensureStableAliasesIndexed();
            value = super.get(identifier);
        }
        if (!Number.isInteger(value)) return value;
        const compactSegment = this.compactSegments[value - 1];
        if (!compactSegment || !this.tables) return undefined;
        const metadata = manabiExpandCompactSegmentMetadata(compactSegment, this.tables);
        for (const alias of manabiSegmentMetadataAliases(metadata)) {
            super.set(alias, metadata);
        }
        this.materializedSegmentCount += 1;
        return metadata;
    }

    has(identifier) {
        return this.get(identifier) !== undefined;
    }
}

class ManabiLazySegmentScopeMap extends Map {
    constructor(compactSegments, scopeTable, scopeTupleIndex) {
        super();
        this.compactSegments = compactSegments;
        this.scopeTable = scopeTable;
        this.scopeTupleIndex = scopeTupleIndex;
        this.isIndexed = false;
    }

    ensureIndexed() {
        if (this.isIndexed) return;
        // Sentence and paragraph pickers are user-driven. Build their deterministic sidecar
        // indexes on first use instead of allocating arrays for the whole section before paint.
        this.isIndexed = true;
        for (const compactSegment of this.compactSegments) {
            const scopeID = manabiSidecarTableValue(
                this.scopeTable,
                compactSegment?.[this.scopeTupleIndex],
                null
            );
            const elementID = manabiExpandSegmentIDToken(compactSegment?.[0]);
            if (typeof scopeID !== 'string' || scopeID.length === 0 || !elementID) continue;
            const existingSegmentIDs = super.get(scopeID);
            if (existingSegmentIDs) {
                existingSegmentIDs.push(elementID);
            } else {
                super.set(scopeID, [elementID]);
            }
        }
    }

    get(identifier) {
        this.ensureIndexed();
        return super.get(identifier);
    }
}

const manabiSegmentMetadataAliases = (segment) => {
    const aliases = [];
    const add = (identifier) => {
        if (typeof identifier !== 'string' || identifier.length === 0) return;
        if (!aliases.includes(identifier)) aliases.push(identifier);
    };
    add(segment?.i);
    add(segment?.sid);
    return aliases;
};

const manabiSegmentMetadataSidecarSnapshot = (doc) => {
    if (!doc) return { sidecars: [], sidecarTexts: [], sidecarPayloads: [], sidecarSignature: 'none' };
    const canonicalSidecar = doc.getElementById?.('mnb-segment-metadata') ?? null;
    // Processed EPUB sections have one canonical Swift-emitted sidecar. Keep this
    // bootstrap O(1); the general reader script owns dynamic multi-sidecar content.
    const sidecars = canonicalSidecar ? [canonicalSidecar] : [];
    const externalEntry = canonicalSidecar ? null : (doc.manabiExternalSegmentSidecar ?? null);
    const cachedSnapshot = doc.__manabiFoliateSegmentMetadataSidecarSnapshot;
    if (cachedSnapshot?.sidecars?.length === sidecars.length
        && sidecars.every((sidecar, index) => cachedSnapshot.sidecars[index] === sidecar)
        && cachedSnapshot.externalEntry === externalEntry) {
        return cachedSnapshot;
    }
    const sidecarTexts = sidecars.length > 0
        ? sidecars.map(sidecar => sidecar.textContent || '')
        : (externalEntry?.payload ? [''] : []);
    // The Swift-produced sidecar node is immutable for the lifetime of its EPUB document, and
    // cache reuse above is already guarded by node identity. Use an identity generation instead
    // of hashing its large JSON text on the first visible load.
    if (canonicalSidecar) {
        doc.__manabiFoliateSegmentMetadataSidecarGeneration =
            (doc.__manabiFoliateSegmentMetadataSidecarGeneration || 0) + 1;
    }
    const sidecarSignature = externalEntry?.signature
        ? `external:${externalEntry.signature}`
        : (canonicalSidecar
            ? `canonical:${doc.__manabiFoliateSegmentMetadataSidecarGeneration}`
            : 'none');
    const snapshot = {
        sidecars,
        sidecarTexts,
        sidecarPayloads: externalEntry?.payload ? [externalEntry.payload] : [],
        sidecarSignature,
        externalEntry,
    };
    doc.__manabiFoliateSegmentMetadataSidecarSnapshot = snapshot;
    return snapshot;
};

const manabiSidecarNumberArray = (value) => Array.isArray(value)
    ? value.filter(item => typeof item === 'number' && Number.isFinite(item))
    : [];

const manabiMaxExampleSentenceCodePointCount = 7000;
const manabiHighSurrogateMinimum = 0xD800;
const manabiHighSurrogateMaximum = 0xDBFF;
const manabiLowSurrogateMinimum = 0xDC00;
const manabiLowSurrogateMaximum = 0xDFFF;
const manabiAmpersandCodeUnit = 0x26;
const manabiApostropheCodeUnit = 0x27;
const manabiQuotationMarkCodeUnit = 0x22;
const manabiLessThanCodeUnit = 0x3C;
const manabiGreaterThanCodeUnit = 0x3E;

const manabiEscapedExampleSentenceHTML = (text) => {
    const escapedParts = [];
    let chunkStart = 0;
    let index = 0;
    let codePointCount = 0;
    while (index < text.length && codePointCount < manabiMaxExampleSentenceCodePointCount) {
        const codeUnit = text.charCodeAt(index);
        let replacement = null;
        switch (codeUnit) {
        case manabiAmpersandCodeUnit:
            replacement = '&amp;';
            break;
        case manabiLessThanCodeUnit:
            replacement = '&lt;';
            break;
        case manabiGreaterThanCodeUnit:
            replacement = '&gt;';
            break;
        case manabiQuotationMarkCodeUnit:
            replacement = '&quot;';
            break;
        case manabiApostropheCodeUnit:
            replacement = '&#39;';
            break;
        default:
            break;
        }
        if (replacement !== null) {
            if (chunkStart < index) {
                escapedParts.push(text.slice(chunkStart, index));
            }
            escapedParts.push(replacement);
            chunkStart = index + 1;
        }
        let codeUnitLength = 1;
        if (
            codeUnit >= manabiHighSurrogateMinimum
            && codeUnit <= manabiHighSurrogateMaximum
            && index + 1 < text.length
        ) {
            const nextCodeUnit = text.charCodeAt(index + 1);
            if (nextCodeUnit >= manabiLowSurrogateMinimum && nextCodeUnit <= manabiLowSurrogateMaximum) {
                codeUnitLength = 2;
            }
        }
        index += codeUnitLength;
        codePointCount += 1;
    }
    if (escapedParts.length === 0) {
        return index === text.length ? text : text.slice(0, index);
    }
    if (chunkStart < index) {
        escapedParts.push(text.slice(chunkStart, index));
    }
    return escapedParts.join('');
};

// Schema v9 derives examples from compact sidecar tuples on demand. This avoids serializing the
// same sentence facts twice and keeps sentence HTML assembly off the initial render path.
const manabiSentenceArchiveEntryFromSidecarSegments = (segments) => {
    let text = '';
    const sentenceJMDictIDs = [];
    const sentenceJMDictIDSet = new Set();
    const archiveSegments = [];
    for (const segment of segments) {
        text += segment.x || segment.s || segment.ns || '';
        const jmdictEntryIDs = manabiSidecarNumberArray(segment.j);
        const primaryEntryID = jmdictEntryIDs[0];
        if (Number.isFinite(primaryEntryID) && !sentenceJMDictIDSet.has(primaryEntryID)) {
            sentenceJMDictIDSet.add(primaryEntryID);
            sentenceJMDictIDs.push(primaryEntryID);
        }
        const segmentIdentifier = segment.sid || '';
        if (segmentIdentifier) {
            archiveSegments.push({
                jmdictEntryIds: jmdictEntryIDs,
                jmnedictEntryIds: manabiSidecarNumberArray(segment.n),
                searchString: segment.s || segment.ns || '',
                segmentIdentifier,
            });
        }
    }

    const sentenceHTML = manabiEscapedExampleSentenceHTML(text);
    for (const segment of archiveSegments) {
        segment.exampleSentence = sentenceHTML;
        segment.exampleSentenceJMDictIDs = sentenceJMDictIDs;
    }
    return {
        sentenceHTML,
        sentenceJMDictIDs,
        segments: archiveSegments,
    };
};

const directSegmentMetadataBootstrap = (doc) => {
    if (!doc) return emptySegmentMetadataBootstrap();
    const { sidecars, sidecarTexts, sidecarPayloads = [], sidecarSignature } = manabiSegmentMetadataSidecarSnapshot(doc);
    const cachedByID = doc.__manabiFoliateSegmentMetadataByID;
    if (
        doc.__manabiFoliateSegmentMetadataParserVersion === manabiSegmentSidecarParserVersion
        && doc.__manabiFoliateSegmentMetadataSignature === sidecarSignature
        && cachedByID instanceof Map
    ) {
        return {
            byID: cachedByID,
            idsByEntryID: doc.__manabiFoliateSegmentIDsByEntryID || new Map(),
            hasEntryIDs: doc.__manabiFoliateSegmentMetadataHasEntryIDs === true,
            segmentIDsBySentenceID: doc.__manabiFoliateSegmentIDsBySentenceID || new Map(),
            segmentIDsByParagraphID: doc.__manabiFoliateSegmentIDsByParagraphID || new Map(),
            segments: doc.__manabiFoliateSegmentMetadataSegments || [],
            aggregates: null,
            sentenceArchive: doc.__manabiFoliateSidecarSentenceArchive || new Map(),
        };
    }
    const idsByEntryID = new Map();
    const segments = [];
    const sentenceArchive = new Map();
    let payload = sidecarPayloads[0] ?? null;
    if (!payload && sidecarTexts[0]) {
        try {
            payload = JSON.parse(sidecarTexts[0]);
        } catch (_error) {}
    }
    const byID = new ManabiLazySegmentMetadataMap(payload);
    const segmentIDsBySentenceID = new ManabiLazySegmentScopeMap(
        byID.compactSegments,
        byID.tables?.sid ?? [],
        9
    );
    const segmentIDsByParagraphID = new ManabiLazySegmentScopeMap(
        byID.compactSegments,
        byID.tables?.pid ?? [],
        10
    );
    const tableHasEntryIDs = (table) => table?.some?.(entryIDs => entryIDs?.some?.(Number.isFinite) === true) === true;
    const hasEntryIDs = tableHasEntryIDs(byID.tables?.j) || tableHasEntryIDs(byID.tables?.n);
    // Keep the existing Map contract while moving sentence string assembly to the lookup that
    // requests it. The segment index above makes each materialization sentence-local.
    const cachedSentenceArchiveEntry = sentenceArchive.get.bind(sentenceArchive);
    sentenceArchive.get = (sentenceID) => {
        const cachedEntry = cachedSentenceArchiveEntry(sentenceID);
        if (cachedEntry) return cachedEntry;
        const sentenceSegmentIDs = segmentIDsBySentenceID.get(sentenceID);
        if (!Array.isArray(sentenceSegmentIDs) || sentenceSegmentIDs.length === 0) return undefined;
        const sentenceSegments = sentenceSegmentIDs
            .map(segmentID => byID.get(segmentID) ?? null)
            .filter(Boolean);
        if (sentenceSegments.length === 0) return undefined;
        const entry = manabiSentenceArchiveEntryFromSidecarSegments(sentenceSegments);
        sentenceArchive.set(sentenceID, entry);
        return entry;
    };
    doc.__manabiFoliateSegmentMetadataParserVersion = manabiSegmentSidecarParserVersion;
    doc.__manabiFoliateSegmentMetadataSignature = sidecarSignature;
    doc.__manabiFoliateSegmentMetadataByID = byID;
    doc.__manabiFoliateSegmentIDsByEntryID = idsByEntryID;
    doc.__manabiFoliateSegmentMetadataHasEntryIDs = hasEntryIDs;
    doc.__manabiFoliateSegmentIDsBySentenceID = segmentIDsBySentenceID;
    doc.__manabiFoliateSegmentIDsByParagraphID = segmentIDsByParagraphID;
    doc.__manabiFoliateSegmentMetadataSegments = segments;
    doc.__manabiFoliateSidecarSentenceArchive = sentenceArchive;
    // manabi_reader.js owns the general reader cache, but processed EPUB documents are
    // immutable and use this compact bootstrap first. Publish the same lazy structures under
    // that cache contract so a later lookup cannot eagerly expand the entire sidecar again.
    doc.manabiSegmentMetadataParserVersion = manabiSegmentSidecarParserVersion;
    doc.manabiSegmentMetadataByID = byID;
    doc.manabiSegmentIDsByEntryID = idsByEntryID;
    doc.manabiSegmentIDsBySentenceID = segmentIDsBySentenceID;
    doc.manabiSegmentIDsByParagraphID = segmentIDsByParagraphID;
    doc.manabiSegmentMetadataSegments = segments;
    doc.manabiSegmentMetadataAggregates = null;
    doc.manabiSidecarSentenceArchive = sentenceArchive;
    doc.manabiSegmentMetadataSidecars = sidecars;
    doc.manabiSegmentMetadataSidecarTexts = sidecarTexts;
    doc.manabiSegmentMetadataSidecarSignature = sidecarSignature;
    doc.manabiSegmentMetadataCacheGeneration = doc.manabiSegmentMetadataGeneration || 0;
    return {
        byID,
        idsByEntryID,
        hasEntryIDs,
        segmentIDsBySentenceID,
        segmentIDsByParagraphID,
        segments,
        aggregates: null,
        sentenceArchive,
    };
};

const MANABI_TEMP_DISABLE_EBOOK_NATIVE_LOOKUP_HIT_TARGETS = false;
globalThis.__manabiEbookNativeLookupHitTargetsDisabled = MANABI_TEMP_DISABLE_EBOOK_NATIVE_LOOKUP_HIT_TARGETS;

const enableInitialRestoreRenderReadyGate = (reason, payload = {}) => {
    globalThis.__manabiInitialRestoreRenderReadyGate = {
        active: true,
        reason,
        restoreKind: payload.restoreKind ?? null,
        requestedFraction: payload.requestedFraction ?? null,
        cfiLength: payload.cfiLength ?? null,
        startedAtMs: Date.now(),
    };
};

const clearInitialRestoreRenderReadyGate = (reason) => {
    if (globalThis.__manabiInitialRestoreRenderReadyGate?.active !== true) {
        return false;
    }
    const gate = globalThis.__manabiInitialRestoreRenderReadyGate;
    globalThis.__manabiInitialRestoreRenderReadyGate = null;
    return true;
};

const markReaderRenderReady = (reason = 'unspecified') => {
    if (globalThis.__manabiInitialRestoreRenderReadyGate?.active === true) {
        const reasonString = String(reason ?? '');
        const allowedByRestore =
            reasonString.startsWith('initialDisplay.restoreSatisfied')
            || reasonString.startsWith('loadEBook.initialRestoreHandled')
            || reasonString.startsWith('initialDisplay.visible-content')
            || reasonString.startsWith('loadLastPosition.initialRestoreAlreadyHandled')
            || reasonString.startsWith('loadLastPosition.syntheticNavigationSettled')
            || reasonString.startsWith('loadLastPosition.done')
        if (!allowedByRestore) {
            return;
        }
        globalThis.__manabiInitialRestoreRenderReadyGate = null;
    }
    const html = document.documentElement;
    const body = document.body;
    const wasReady = html?.dataset?.mnbReaderRenderReady === '1'
        || body?.dataset?.mnbReaderRenderReady === '1';
    if (html?.dataset) {
        html.dataset.mnbReaderRenderReady = '1';
    }
    if (body?.dataset) {
        body.dataset.mnbReaderRenderReady = '1';
    }
    if (!wasReady) {
    }
    globalThis.__manabiPostReaderDocStateEvent?.(`renderReady.${reason}`);
};

const finishInitialRestoreRenderReadyGateWithTerminalResult = (reason = 'initialRestore.terminalResult') => {
    clearInitialRestoreRenderReadyGate(reason);
    markReaderRenderReady(reason);
};

const nextEbookLoadRequestID = (prefix) => {
    globalThis.__manabiEBookLoadRequestSeq = (globalThis.__manabiEBookLoadRequestSeq ?? 0) + 1;
    return `${prefix}-${globalThis.__manabiEBookLoadRequestSeq}`;
};

const ignoredWindowErrorMessages = new Set([
    'ResizeObserver loop completed with undelivered notifications.',
]);

const shouldIgnoreWindowError = message => ignoredWindowErrorMessages.has(String(message ?? ''));

window.onerror = function(msg, source, lineno, colno, error) {
    if (shouldIgnoreWindowError(msg)) return true;
    window.webkit?.messageHandlers?.readerOnError?.postMessage?.({
        message: msg,
        source: source,
        lineno: lineno,
        colno: colno,
        error: String(error)
    });
};

window.onunhandledrejection = function(event) {
    window.webkit?.messageHandlers?.readerOnError?.postMessage?.({
        message: event.reason?.message ?? "Unhandled rejection",
        source: window.location.href,
        lineno: null,
        colno: null,
        error: event.reason?.stack ?? String(event.reason)
    });
};

function forwardShadowErrors(root) {
    if (!root) return;
    root.addEventListener('error', e => {
        window.webkit?.messageHandlers?.readerOnError?.postMessage?.({
            message: e.message || e.error?.message || 'Shadow-DOM error',
            source: window.location.href,
            lineno: e.lineno || 0,
            colno: e.colno || 0,
            error: e.error?.stack || String(e.error || e)
        });
    });
    root.addEventListener('unhandledrejection', e => {
        window.webkit?.messageHandlers?.readerOnError?.postMessage?.({
            message: e.reason?.message || 'Shadow-DOM unhandled rejection',
            source: window.location.href,
            lineno: 0,
            colno: 0,
            error: e.reason?.stack || String(e.reason)
        });
    });
}

const roundedDisplayPercent = value => {
    if (typeof value !== 'number' || !Number.isFinite(value)) {
        return null;
    }
    return Math.round(Math.max(0, Math.min(1, value)) * 100);
};

const describeMarkReadNode = (node) => {
    if (!node) return null;
    const element = node.nodeType === Node.ELEMENT_NODE
        ? node
        : (node.parentElement || null);
    if (!element) {
        return {
            nodeType: node.nodeType ?? null,
            nodeName: node.nodeName || null,
        };
    }
    return {
        nodeType: node.nodeType ?? null,
        nodeName: node.nodeName || null,
        elementTag: element.tagName || null,
        elementID: element.id || null,
        classSample: typeof element.className === 'string'
            ? element.className.split(/\s+/).filter(Boolean).slice(0, 4)
            : [],
        segmentIdentifier: segmentIdentifierForNode(element),
        sentenceIdentifier: sentenceIdentifierForNode(element.closest?.(manabiReaderSentenceSelector) || null),
    };
};



const parseSpineOnlyEpubCFI = (value) => {
    if (typeof value !== 'string') return null;
    const match = value.trim().match(/^epubcfi\(\s*\/6\/(\d+)(?:\[[^\]]*\])?\s*\)$/);
    if (!match) return null;
    const spineStep = Number(match[1]);
    if (!Number.isInteger(spineStep) || spineStep <= 0 || spineStep % 2 !== 0) return null;
    return (spineStep / 2) - 1;
};

const coerceRestoreFraction = (...values) => {
    const numbers = values
        .map((value) => {
            if (typeof value === 'number') return value;
            if (typeof value === 'string' && value.trim().length > 0) return Number(value);
            return NaN;
        })
        .filter((value) => Number.isFinite(value))
        .map((value) => Math.max(0, Math.min(1, value)));
    return numbers.find((value) => value > 0) ?? numbers[0] ?? null;
};

const visibleEntryIDsForMetadata = (metadata) => {
    const jmdictEntryIDs = Array.isArray(metadata?.j) ? metadata.j : [];
    const jmnedictEntryIDs = Array.isArray(metadata?.n) ? metadata.n : [];
    return jmdictEntryIDs.length > 0 ? jmdictEntryIDs : jmnedictEntryIDs;
};

const visiblePrimeMetadataForElementID = (doc, index, elementID) => {
    if (typeof elementID !== 'string' || elementID.length === 0) {
        return null;
    }
    const indexedMetadata = index?.byElementID?.get?.(elementID)
        || index?.bySegmentIdentifier?.get?.(elementID)
        || null;
    if (visibleEntryIDsForMetadata(indexedMetadata).length > 0) {
        return indexedMetadata;
    }
    const segment = doc?.getElementById?.(elementID) ?? null;
    const sidecarMetadata = segmentMetadataForNode(segment)
        || segmentMetadataBootstrap(doc).byID.get(elementID)
        || null;
    if (visibleEntryIDsForMetadata(sidecarMetadata).length > 0) {
        if (index?.byElementID instanceof Map) {
            const mergedMetadata = {
                ...(indexedMetadata || {}),
                ...sidecarMetadata,
            };
            index.byElementID.set(elementID, mergedMetadata);
            const segmentIdentifier = mergedMetadata.sid || null;
            if (typeof segmentIdentifier === 'string' && segmentIdentifier.length > 0 && index.bySegmentIdentifier instanceof Map) {
                index.bySegmentIdentifier.set(segmentIdentifier, mergedMetadata);
            }
            return mergedMetadata;
        }
        return sidecarMetadata;
    }
    return indexedMetadata;
};

const visiblePrimeEntryIDsForIndex = (doc, index, visibleElementIDs) => {
    if (!(index?.byElementID instanceof Map)) {
        return [];
    }
    const entryIDs = [];
    const seen = new Set();
    for (const elementID of visibleElementIDs || []) {
        const metadata = visiblePrimeMetadataForElementID(doc, index, elementID);
        const ids = visibleEntryIDsForMetadata(metadata);
        for (const rawEntryID of ids) {
            const entryID = Number(rawEntryID);
            if (!Number.isFinite(entryID) || seen.has(entryID)) {
                continue;
            }
            seen.add(entryID);
            entryIDs.push(entryID);
        }
    }
    return entryIDs;
};

const visiblePrimeSignatureForIndex = (visibleElementIDs, entryIDs) => {
    return `${(visibleElementIDs || []).join(',')}|${(entryIDs || []).join(',')}`;
};

const visibleLookupIndexNeedsSidecarRefresh = (doc, index) => {
    if (!isDocumentLike(doc) || !index || !(index.byElementID instanceof Map)) {
        return false;
    }
    const visibleElementIDs = Array.isArray(index.visibleElementIDs) ? index.visibleElementIDs : [];
    if (visibleElementIDs.length === 0 || visiblePrimeEntryIDsForIndex(doc, index, visibleElementIDs).length > 0) {
        return false;
    }
    const bootstrap = segmentMetadataBootstrap(doc);
    return bootstrap.hasEntryIDs === true;
};

const requestNativeVisibleTrackedWordsPrime = (doc, index, reason = 'visible-prime') => {
    if (!isDocumentLike(doc) || !index || !isEbookContentDocument(doc)) {
        manabiTimelineMark('visiblePrime.request.skip', { reason, skipReason: 'invalid-context' });
        return false;
    }
    const view = doc.defaultView;
    const visibleElementIDs = Array.isArray(index.visibleElementIDs)
        ? Array.from(new Set(index.visibleElementIDs.filter((elementID) => typeof elementID === 'string' && elementID.length > 0)))
        : [];
    if (visibleElementIDs.length === 0 || !(index.byElementID instanceof Map)) {
        manabiTimelineMark('visiblePrime.request.skip', {
            reason,
            skipReason: visibleElementIDs.length === 0 ? 'empty-visible-elements' : 'missing-element-index',
            visibleElementIDCount: visibleElementIDs.length,
        });
        return false;
    }
    const entryIDs = visiblePrimeEntryIDsForIndex(doc, index, visibleElementIDs);
    if (entryIDs.length === 0) {
        manabiTimelineMark('visiblePrime.request.skip', {
            reason,
            skipReason: 'empty-entry-ids',
            visibleElementIDCount: visibleElementIDs.length,
        });
        return false;
    }
    const signature = visiblePrimeSignatureForIndex(visibleElementIDs, entryIDs);
    if (view.__manabiLastNativeVisiblePrimeSignature === signature) {
        manabiTimelineMark('visiblePrime.request.skip', {
            reason,
            skipReason: 'duplicate-signature',
            visibleElementIDCount: visibleElementIDs.length,
            entryIDCount: entryIDs.length,
        });
        return false;
    }
    try {
        const handler = view.webkit?.messageHandlers?.manabiSegmentsReady;
        if (typeof handler?.postMessage !== 'function') {
            manabiTimelineMark('visiblePrime.request.skip', {
                reason,
                skipReason: 'missing-native-handler',
                visibleElementIDCount: visibleElementIDs.length,
                entryIDCount: entryIDs.length,
            });
            return false;
        }
        const uuid = typeof view.manabiCurrentFrameUUID === 'function'
            ? view.manabiCurrentFrameUUID()
            : doc.body?.dataset?.swiftuiwebviewFrameUuid ?? null;
        handler.postMessage({
            windowURL: window.top.location.href,
            pageURL: doc.location?.href || doc.URL || '',
            isCacheWarmer: doc.body?.dataset?.isCacheWarmer === 'true',
            isReaderMode: doc.body?.classList?.contains?.('readability-mode') === true,
            reason,
            segmentCount: visibleElementIDs.length,
            force: false,
            uuid,
            visiblePrimeOnly: true,
            visibleElementIDs,
            entryIDs,
        });
        view.__manabiLastNativeVisiblePrimeSignature = signature;
        manabiTimelineMark('visiblePrime.request.sent', {
            reason,
            visibleElementIDCount: visibleElementIDs.length,
            entryIDCount: entryIDs.length,
            uuidPresent: typeof uuid === 'string' && uuid.length > 0,
        });
        return true;
    } catch (error) {
        manabiTimelineMark('visiblePrime.request.error', {
            reason,
            error: String(error),
            visibleElementIDCount: visibleElementIDs.length,
            entryIDCount: entryIDs.length,
        });
        return false;
    }
};

const getPrimaryRendererContentIndex = (renderer) => {
    try {
        const contents = renderer?.getContents?.();
        const primaryContent = Array.isArray(contents) && contents.length > 0 ? contents[0] ?? null : null;
        return typeof primaryContent?.index === 'number' ? primaryContent.index : null;
    } catch (_error) {
        return null;
    }
};

const captureNavVisibilityState = () => {
    const body = document.body;
    const navBar = document.getElementById('nav-bar');
    const navPrimaryText = document.getElementById('nav-primary-text');
    return {
        bodyNavHiddenClass: body?.classList?.contains?.('nav-hidden') ?? null,
        navHiddenClass: navBar?.classList?.contains?.('nav-hidden') ?? null,
        navHiddenScrollClass: navBar?.classList?.contains?.('nav-hidden-due-to-scroll') ?? null,
        hudHideNavigationDueToScroll: !!globalThis.reader?.navHUD?.hideNavigationDueToScroll,
        hudNavHidden: !!globalThis.reader?.navHUD?.navHidden,
        labelVariant: navPrimaryText?.dataset?.labelVariant ?? null,
        primaryLabel: document.getElementById('nav-primary-text-full')?.textContent
            || navPrimaryText?.textContent
            || '',
        compactLabel: document.getElementById('nav-primary-text-compact')?.textContent || '',
    };
};

const eventClientPoint = (event) => {
    const touch = event?.changedTouches?.[0] || event?.touches?.[0] || null;
    const clientX = Number(touch?.clientX ?? event?.clientX);
    const clientY = Number(touch?.clientY ?? event?.clientY);
    return Number.isFinite(clientX) && Number.isFinite(clientY) ? { clientX, clientY } : null;
};

const isEventInsideElementCircle = (event, element, slop = 2) => {
    if (!(element instanceof Element)) {
        return true;
    }
    const point = eventClientPoint(event);
    const rect = element.getBoundingClientRect?.();
    if (!point || !rect || rect.width <= 0 || rect.height <= 0) {
        return true;
    }
    const radius = Math.min(rect.width, rect.height) / 2 + slop;
    const dx = point.clientX - (rect.left + rect.width / 2);
    const dy = point.clientY - (rect.top + rect.height / 2);
    return Math.hypot(dx, dy) <= radius;
};

const REPLACE_TEXT_RESULT_CACHE_LIMIT = 64;
const replaceTextResultCache = new Map();
const replaceTextInFlightCache = new Map();

const fingerprintReplaceTextInput = (text) => {
    if (typeof text !== 'string') return 'invalid';
    let hash = 2166136261;
    for (let i = 0; i < text.length; i += 1) {
        hash ^= text.charCodeAt(i);
        hash = Math.imul(hash, 16777619);
    }
    return `${text.length}:${(hash >>> 0).toString(16)}`;
};

const makeReplaceTextCacheKey = ({ href, text }) => {
    return `neutral|${href || 'nil'}|${fingerprintReplaceTextInput(text)}`;
};

const rememberReplaceTextResult = (key, value) => {
    replaceTextResultCache.delete(key);
    replaceTextResultCache.set(key, value);
    while (replaceTextResultCache.size > REPLACE_TEXT_RESULT_CACHE_LIMIT) {
        const oldestKey = replaceTextResultCache.keys().next().value;
        replaceTextResultCache.delete(oldestKey);
    }
};

const adaptReplaceTextHTMLForMode = (html, { href }) => {
    const hasSentences = typeof html === 'string' && /<m-s\b/i.test(html);
    const hasSegments = typeof html === 'string' && /<m-m\b/i.test(html);
    return injectBodyDatasetAttributes(html, {
        'data-mnb-source-href': href,
        'data-mnb-has-sentences': hasSentences ? 'true' : null,
        'data-mnb-has-segments': hasSegments ? 'true' : null,
    });
};

const makeReplaceText = ({ allowForegroundHTML = true } = {}) => async (href, text, mediaType) => {
    if (mediaType !== 'application/xhtml+xml' && mediaType !== 'text/html' /* && mediaType !== 'application/xml'*/ ) {
        return text;
    }
    if (!allowForegroundHTML) {
        throw new Error(`Foreground native EPUB section must load through processed-section direct URL: ${href || 'nil'}`);
    }
    const cacheKey = makeReplaceTextCacheKey({
        href,
        text,
    });
    if (replaceTextResultCache.has(cacheKey)) {
        const cachedNeutralHTML = replaceTextResultCache.get(cacheKey);
        const cachedHTML = adaptReplaceTextHTMLForMode(cachedNeutralHTML, { href });
        replaceTextResultCache.delete(cacheKey);
        replaceTextResultCache.set(cacheKey, cachedNeutralHTML);
        window.manabi_recordLiveProcessedSection?.(href);
        return cachedHTML;
    }
    if (replaceTextInFlightCache.has(cacheKey)) {
        const neutralHTML = await replaceTextInFlightCache.get(cacheKey);
        const html = adaptReplaceTextHTMLForMode(neutralHTML, { href });
        window.manabi_recordLiveProcessedSection?.(href);
        return html;
    }
    const run = async () => {
    const replaceTextStartedAt = performanceNowMs();
    const processTextRequestID = nextEbookLoadRequestID('process-text');
    const sourceURL = globalThis.reader.view.ownerDocument.defaultView.top.location.href;
    const requestBytes = 0;
    const transport = 'processed-section-get';
    manabiTimelineMark('processText.start', {
        requestID: processTextRequestID,
        href,
        requestBytes,
        transport,
    });
    globalThis.__manabiInflightReplaceTextCount = (globalThis.__manabiInflightReplaceTextCount ?? 0) + 1;
    globalThis.__manabiInflightLiveReplaceTextCount = (globalThis.__manabiInflightLiveReplaceTextCount ?? 0) + 1;
    const normalizedHref = normalizeSpineHref(href);
    if (normalizedHref && !firstLiveSectionHref()) {
        globalThis.__manabiFirstLiveSectionHref = normalizedHref;
    }
    const headers = {
        "X-Replaced-Text-Location": href,
        "X-Content-Location": sourceURL,
        "X-Ebook-Source-URL": sourceURL,
    };
    const requestURL = `ebook://ebook/processed-section?sourceURL=${encodeURIComponent(sourceURL)}&subpath=${encodeURIComponent(href)}`;
    const requestOptions = {
        method: "GET",
        mode: "cors",
        cache: "no-cache",
        headers: headers,
    };
    const fetchStartedAt = performanceNowMs();
    const response = await fetch(requestURL, requestOptions).catch((error) => {
        throw error;
    })
    const responseHeadersElapsedMs = performanceNowMs() - fetchStartedAt;
    manabiTimelineMeasure('processText.fetchHeaders', fetchStartedAt, {
        requestID: processTextRequestID,
        href,
        status: response?.status ?? null,
        transport,
    }, 50);
    try {
        if (!response.ok) {
            throw new Error(`HTTP error, status = ${response.status}`)
        }
        const textStartedAt = performanceNowMs();
        let html = await response.text()
        const responseTextElapsedMs = performanceNowMs() - textStartedAt;
        const responseTextLength = html.length;
        const nativeCacheOutcome = response.headers?.get?.('x-manabi-process-cache') || null;
        const nativeResponseReadyElapsedMs = Number(response.headers?.get?.('x-manabi-response-ready-elapsed-ms'));
        const nativeResponseEncodeElapsedMs = Number(response.headers?.get?.('x-manabi-response-encode-elapsed-ms'));
        const nativeDidCoalesce = response.headers?.get?.('x-manabi-did-coalesce') || null;
        manabiTimelineMeasure('processText.responseText', textStartedAt, {
            requestID: processTextRequestID,
            href,
            responseBytes: responseTextLength,
            nativeCache: nativeCacheOutcome,
            transport,
            nativeResponseReadyElapsedMs: Number.isFinite(nativeResponseReadyElapsedMs) ? nativeResponseReadyElapsedMs : null,
            nativeResponseEncodeElapsedMs: Number.isFinite(nativeResponseEncodeElapsedMs) ? nativeResponseEncodeElapsedMs : null,
            nativeDidCoalesce,
        }, 50);
        manabiTimelineMeasure('processText', replaceTextStartedAt, {
            requestID: processTextRequestID,
            href,
            requestBytes,
            responseBytes: responseTextLength,
            nativeCache: nativeCacheOutcome,
            transport,
            fetchHeadersElapsedMs: responseHeadersElapsedMs,
            responseTextElapsedMs,
            nativeResponseReadyElapsedMs: Number.isFinite(nativeResponseReadyElapsedMs) ? nativeResponseReadyElapsedMs : null,
            nativeResponseEncodeElapsedMs: Number.isFinite(nativeResponseEncodeElapsedMs) ? nativeResponseEncodeElapsedMs : null,
            nativeDidCoalesce,
        });
        rememberReplaceTextResult(cacheKey, html);
        return html
    } catch (error) {
        console.error("Error replacing text:", error)
        return text
    } finally {
        globalThis.__manabiInflightReplaceTextCount = Math.max(0, (globalThis.__manabiInflightReplaceTextCount ?? 1) - 1);
        globalThis.__manabiInflightLiveReplaceTextCount = Math.max(0, (globalThis.__manabiInflightLiveReplaceTextCount ?? 1) - 1);
    }
    };
    const promise = run();
    replaceTextInFlightCache.set(cacheKey, promise);
    try {
        const neutralHTML = await promise;
        const html = adaptReplaceTextHTMLForMode(neutralHTML, { href });
        window.manabi_recordLiveProcessedSection?.(href);
        return html;
    } finally {
        replaceTextInFlightCache.delete(cacheKey);
    }
}

const processedSectionURLForHref = (sourceURL, href, writingDirection = null) => {
    const params = new URLSearchParams({
        sourceURL,
        subpath: href,
        direct: '1',
    });
    if (writingDirection?.direction) params.set('mnbWritingDirection', writingDirection.direction);
    if (writingDirection?.writingMode) params.set('mnbWritingMode', writingDirection.writingMode);
    return `ebook://ebook/processed-section?${params.toString()}`;
};

const observedBookWritingDirectionFallback = () => {
    const direction = globalThis.__manabiObservedBookWritingDirection;
    const writingMode = globalThis.__manabiObservedBookWritingMode;
    if (direction !== 'vertical') return null;
    return {
        direction: 'vertical',
        writingMode: writingMode === 'vertical-lr' ? 'vertical-lr' : 'vertical-rl',
        source: 'observed-book',
    };
};

const seedObservedBookWritingDirection = (direction, writingMode = null, source = 'unknown') => {
    if (direction !== 'vertical') return false;
    const normalizedWritingMode = writingMode === 'vertical-lr' ? 'vertical-lr' : 'vertical-rl';
    if (globalThis.__manabiObservedBookWritingDirection === 'vertical'
        && globalThis.__manabiObservedBookWritingMode === normalizedWritingMode) {
        return false;
    }
    globalThis.__manabiObservedBookWritingDirection = 'vertical';
    globalThis.__manabiObservedBookWritingMode = normalizedWritingMode;
    manabiTimelineMark('processText.directionFallback.seedObservedBook', {
        source,
        writingDirection: 'vertical',
        writingMode: normalizedWritingMode,
    });
    return true;
};

const resolveEpubRelativePath = (url, relativeTo) => {
    try {
        if (String(relativeTo || '').includes(':')) return new URL(url, relativeTo).href;
        const root = 'https://invalid.invalid/';
        const obj = new URL(url, root + relativeTo);
        obj.search = '';
        return decodeURI(obj.href.replace(root, ''));
    } catch (_error) {
        return url;
    }
};

const computeRawSectionWritingDirectionFromText = async (href, text, loadText) => {
    if (!text || typeof DOMParser !== 'function') return null;
    const doc = new DOMParser().parseFromString(text, 'application/xhtml+xml');
    if (!doc?.documentElement || doc.querySelector?.('parsererror')) return null;

    const cloneDoc = document.implementation.createHTMLDocument();
    const clonedHead = doc.head?.cloneNode?.(true) ?? cloneDoc.createElement('head');
    clonedHead.querySelectorAll?.('script')?.forEach?.(el => el.remove());

    const stylesheetLinks = Array.from(clonedHead.querySelectorAll?.('link[rel="stylesheet"][href]') ?? []);
    const blobURLs = [];
    for (const link of stylesheetLinks) {
        const stylesheetHref = link.getAttribute('href');
        if (!stylesheetHref || /^(?:https?:|data:|blob:)/i.test(stylesheetHref)) continue;
        const resolvedHref = resolveEpubRelativePath(stylesheetHref, href);
        try {
            const css = await loadText?.(resolvedHref);
            if (!css) continue;
            const blobURL = URL.createObjectURL(new Blob([css], { type: 'text/css' }));
            blobURLs.push(blobURL);
            link.href = blobURL;
        } catch (_error) {}
    }

    const bodyClone = doc.body?.cloneNode?.(false) ?? cloneDoc.createElement('body');
    cloneDoc.head.replaceWith(clonedHead);
    cloneDoc.body.replaceWith(bodyClone);
    for (const { name, value } of Array.from(doc.documentElement?.attributes ?? [])) {
        cloneDoc.documentElement.setAttribute(name, value);
    }

    const iframe = document.createElement('iframe');
    iframe.style.cssText = 'position:fixed;visibility:hidden;width:0;height:0;border:0;contain:strict;';
    document.documentElement.appendChild(iframe);
    const blobURL = URL.createObjectURL(new Blob(
        ['<!doctype html>', cloneDoc.documentElement.outerHTML],
        { type: 'text/html' },
    ));
    blobURLs.push(blobURL);

    try {
        await new Promise(resolve => {
            iframe.onload = resolve;
            iframe.src = blobURL;
        });
        await new Promise(resolve => scheduleNextFrame(resolve));
        const probeDoc = iframe.contentDocument;
        const bodyStyle = iframe.contentWindow?.getComputedStyle?.(probeDoc?.body);
        const rootStyle = iframe.contentWindow?.getComputedStyle?.(probeDoc?.documentElement);
        const writingMode = (
            bodyStyle?.writingMode?.trim?.().toLowerCase?.()
            || rootStyle?.writingMode?.trim?.().toLowerCase?.()
            || ''
        );
        const direction = bodyStyle?.direction?.trim?.().toLowerCase?.() || rootStyle?.direction?.trim?.().toLowerCase?.() || null;
        const hasVerticalWritingClass =
            probeDoc?.body?.classList?.contains?.('reader-vertical-writing') === true
            || probeDoc?.documentElement?.classList?.contains?.('vrtl') === true;
        if (writingMode === 'vertical-rl' || writingMode === 'vertical-lr') {
            return { direction: 'vertical', writingMode };
        }
        if (hasVerticalWritingClass) {
            return { direction: 'vertical', writingMode: 'vertical-rl' };
        }
        const rootClass = String(probeDoc?.documentElement?.className ?? '');
        const bodyClass = String(probeDoc?.body?.className ?? '');
        if (writingMode === 'horizontal-tb'
            && (
                rootClass.split(/\s+/).includes('hltr')
                || bodyClass.length > 0
            )) {
            return { direction: 'horizontal', writingMode: 'horizontal-tb' };
        }
        return null;
    } finally {
        iframe.remove();
        for (const url of blobURLs) {
            try { URL.revokeObjectURL(url); } catch (_error) {}
        }
    }
};

const rawSectionWritingDirectionCache = new Map();
const computeRawSectionWritingDirection = async (sourceURL, href, loadText = null) => {
    const cacheKey = `${sourceURL || ''}|${href || ''}`;
    if (rawSectionWritingDirectionCache.has(cacheKey)) {
        return rawSectionWritingDirectionCache.get(cacheKey);
    }
    const startedAt = performanceNowMs();
    const probePromise = new Promise((resolve) => {
        if (!sourceURL || !href) {
            resolve(null);
            return;
        }
        const iframe = document.createElement('iframe');
        let settled = false;
        const finish = (value) => {
            if (settled) return;
            settled = true;
            clearTimeout(timeout);
            iframe.remove();
            resolve(value);
        };
        const timeout = setTimeout(() => finish(null), 1200);
        const finishWithRawText = async () => {
            if (typeof loadText !== 'function') return false;
            try {
                const rawText = await loadText(href);
                const rawDirection = await computeRawSectionWritingDirectionFromText(href, rawText, loadText);
                if (rawDirection) {
                    finish(rawDirection);
                    return true;
                }
            } catch (_error) {
            }
            return false;
        };
        const startURLProbe = () => {
            if (settled) return;
            iframe.style.cssText = 'position:absolute;width:0;height:0;border:0;visibility:hidden;pointer-events:none;';
            iframe.addEventListener('load', () => {
                try {
                    const doc = iframe.contentDocument;
                    const body = doc?.body;
                    const root = doc?.documentElement;
                    const bodyStyle = iframe.contentWindow?.getComputedStyle?.(body);
                    const rootStyle = iframe.contentWindow?.getComputedStyle?.(root);
                    const writingMode = (
                        bodyStyle?.writingMode?.trim?.().toLowerCase?.()
                        || rootStyle?.writingMode?.trim?.().toLowerCase?.()
                        || ''
                    );
                    if (writingMode === 'vertical-rl' || writingMode === 'vertical-lr') {
                        finish({ direction: 'vertical', writingMode });
                        return;
                    }
                } catch (_error) {}
                finish(null);
            }, { once: true });
            iframe.addEventListener('error', () => finish(null), { once: true });
            document.documentElement.appendChild(iframe);
            try {
                const sectionURL = new URL(sourceURL);
                sectionURL.searchParams.set('subpath', href);
                sectionURL.searchParams.set('directionProbe', '1');
                iframe.src = sectionURL.toString();
            } catch (_error) {
                iframe.src = `${sourceURL}?subpath=${encodeURIComponent(href)}&directionProbe=1`;
            }
        };
        void finishWithRawText().then(done => {
            if (!done) startURLProbe();
        });
    });
    rawSectionWritingDirectionCache.set(cacheKey, probePromise);
    return probePromise;
};

function makeReplaceURL(sourceURL, loadText = null) {
    return async (href, mediaType) => {
        if (mediaType !== 'application/xhtml+xml' && mediaType !== 'text/html') {
            return null;
        }
        if (!href) {
            throw new Error('Direct processed section URL requires a spine href');
        }
        const writingDirection =
            await computeRawSectionWritingDirection(sourceURL, href, loadText)
            ?? observedBookWritingDirectionFallback();
        const directURL = processedSectionURLForHref(sourceURL, href, writingDirection);
        window.manabi_recordLiveProcessedSection?.(href);
        manabiTimelineMark('processText.directURL', {
            href,
            mediaType,
            transport: 'processed-section-url',
            requestBytes: 0,
            writingDirection: writingDirection?.direction ?? null,
            writingMode: writingDirection?.writingMode ?? null,
        });
        return directURL;
    };
}

const debounce = (fn, delay) => {
    let timeout = null;
    let latestArgs = null;
    let latestContext = null;

    const debounced = function(...args) {
        latestArgs = args;
        latestContext = this;
        if (timeout) {
            clearTimeout(timeout);
        }
        timeout = setTimeout(() => {
            const callArgs = latestArgs;
            const callContext = latestContext;
            timeout = null;
            latestArgs = null;
            latestContext = null;
            fn.apply(callContext, callArgs ?? []);
        }, delay);
    };

    debounced.cancel = () => {
        if (timeout) {
            clearTimeout(timeout);
            timeout = null;
        }
        latestArgs = null;
        latestContext = null;
    };

    return debounced;
};

const visibleJapaneseTextStateForVisibleSegmentsResult = (visibleSegmentsResult = null) => {
    let visibleSegmentCount = 0;
    for (const item of visibleSegmentsResult?.visibleSegments || []) {
        if ((item.node?.textContent || '').trim()) {
            visibleSegmentCount += 1;
        }
    }
    return {
        hasVisibleJapaneseText: visibleSegmentCount > 0,
        visibleSegmentCount,
        observedSegmentCount: visibleSegmentsResult?.totalSegmentCount ?? 0,
    };
};

const visibleRenderableContentStateForDocument = (doc, visibleSegmentsResult = null) => {
    const textState = visibleJapaneseTextStateForVisibleSegmentsResult(visibleSegmentsResult);
    if (textState.hasVisibleJapaneseText === true) {
        return {
            ...textState,
            hasVisibleSingleMedia: false,
            hasRenderableContent: true,
        };
    }
    const body = doc?.body ?? null;
    let hasVisibleSingleMedia = false;
    if (body?.classList?.contains?.('reader-is-single-media-element-without-text') === true) {
        const media = body.querySelector?.('img, svg, image, picture, video, object') ?? null;
        const rect = media?.getBoundingClientRect?.() ?? null;
        const style = media && doc?.defaultView?.getComputedStyle
            ? doc.defaultView.getComputedStyle(media)
            : null;
        hasVisibleSingleMedia = !!rect
            && rect.width > 1
            && rect.height > 1
            && style?.display !== 'none'
            && style?.visibility !== 'hidden'
            && Number.parseFloat(style?.opacity || '1') > 0.01;
    }
    return {
        ...textState,
        hasVisibleSingleMedia,
        hasRenderableContent: textState.hasVisibleJapaneseText === true || hasVisibleSingleMedia,
    };
};

const getVisibleJapaneseTextStateForRenderer = (renderer, visibleRange = null, visibleSegmentsResult = null) => {
    if (visibleSegmentsResult) {
        return visibleJapaneseTextStateForVisibleSegmentsResult(visibleSegmentsResult);
    }
    if (globalThis.__manabiAvoidVisibleSegmentCollectionForProgress !== false) {
        return {
            hasVisibleJapaneseText: false,
            visibleSegmentCount: 0,
            observedSegmentCount: 0,
        };
    }
    const contents = renderer?.getContents?.() || [];
    const currentIndex = getPrimaryRendererContentIndex(renderer);
    const activeContents = typeof currentIndex === 'number'
        ? contents.filter((content) => typeof content?.index !== 'number' || content.index === currentIndex)
        : contents;
    let observedSegmentCount = 0;
    let visibleSegmentCount = 0;

    for (const content of activeContents) {
        const doc = content?.doc || content?.document || null;
        if (!doc?.querySelectorAll) { continue; }
        const contentVisibleRange = visibleRange?.commonAncestorContainer?.ownerDocument === doc
            || visibleRange?.startContainer?.ownerDocument === doc
            || visibleRange?.endContainer?.ownerDocument === doc
            ? visibleRange
            : null;
        const visibleSegmentsResult = collectVisibleSegmentNodesFromRange(doc, contentVisibleRange);
        observedSegmentCount += visibleSegmentsResult.totalSegmentCount ?? 0;
        for (const item of visibleSegmentsResult.visibleSegments || []) {
            if ((item.node?.textContent || '').trim()) {
                visibleSegmentCount += 1;
            }
        }
    }

    return {
        hasVisibleJapaneseText: visibleSegmentCount > 0,
        visibleSegmentCount,
        observedSegmentCount,
    };
};

const roundLayoutNumber = (value, digits = 1) => {
    const number = Number(value);
    return Number.isFinite(number) ? Number(number.toFixed(digits)) : null;
};

const manabiElementTextContainsJapanese = (element) => /[\u3040-\u30ff\u3400-\u9fff]/.test(element?.textContent ?? '');

const normalizeManabiSegmentWhitespace = (doc) => {
    try {
        if (!doc?.body || isCacheWarmerDocument(doc)) return;
        const shouldRemoveInterSegmentWhitespace =
            doc.body.classList?.contains?.('reader-vertical-writing') === true
            && doc.body.dataset?.isEbook === 'true';
        if (shouldRemoveInterSegmentWhitespace) {
            const segments = doc.getElementsByTagName?.('m-m') ?? [];
            for (let index = 0; index < segments.length; index += 1) {
                const previous = segments[index];
                const removableNodes = [];
                let sibling = previous.nextSibling;
                let gapContainsText = false;
                while (sibling && sibling.nodeType !== Node.ELEMENT_NODE) {
                    if (sibling.nodeType === Node.TEXT_NODE) {
                        const value = sibling.nodeValue ?? '';
                        if (value.length > 0 && !/^\s+$/.test(value)) {
                            gapContainsText = true;
                            break;
                        }
                        if (value.length > 0) {
                            removableNodes.push(sibling);
                        }
                    }
                    sibling = sibling.nextSibling;
                }
                if (gapContainsText || sibling?.tagName?.toLowerCase?.() !== 'm-m') continue;
                if (!manabiElementTextContainsJapanese(previous) || !manabiElementTextContainsJapanese(sibling)) continue;
                for (const node of removableNodes) {
                    node.remove();
                }
            }
        }
        if (doc.body.dataset?.mnbSegmentWhitespaceCompacted !== 'true') {
            for (const segment of doc.querySelectorAll?.('m-m') ?? []) {
                for (const containerNode of [segment, ...Array.from(segment.querySelectorAll?.('ruby') ?? [])]) {
                    for (const node of Array.from(containerNode.childNodes ?? [])) {
                        if (node?.nodeType === Node.TEXT_NODE && /^\s*$/.test(node.nodeValue ?? '')) {
                            node.remove();
                        }
                    }
                }
                for (const inlineNode of segment.querySelectorAll?.('m-t, rt') ?? []) {
                    for (const node of Array.from(inlineNode.childNodes ?? [])) {
                        if (node?.nodeType !== Node.TEXT_NODE) continue;
                        const value = node.nodeValue ?? '';
                        const trimmed = value.trim();
                        if (trimmed.length > 0 && trimmed !== value) {
                            node.nodeValue = trimmed;
                        }
                    }
                }
            }
        }
    } catch (_error) {}
};


const isCacheWarmerDocument = (doc) => doc?.body?.dataset?.isCacheWarmer === 'true';

const beginForegroundCriticalSection = (reason = 'unspecified') => {
    globalThis.__manabiForegroundCriticalSectionSequence =
        (globalThis.__manabiForegroundCriticalSectionSequence ?? 0) + 1;
    const token = `foreground-${globalThis.__manabiForegroundCriticalSectionSequence}`;
    globalThis.__manabiForegroundCriticalSectionTokens ??= new Set();
    globalThis.__manabiForegroundCriticalSectionTokens.add(token);
    globalThis.__manabiForegroundCriticalSectionCount = globalThis.__manabiForegroundCriticalSectionTokens.size;
    manabiTimelineMark('foregroundCriticalSection.start', {
        reason,
        token,
        count: globalThis.__manabiForegroundCriticalSectionCount,
    });
    try {
        window.webkit?.messageHandlers?.ebookForegroundCriticalSection?.postMessage({
            phase: 'begin',
            reason,
            token,
        });
    } catch (_error) {}
    return token;
};

const finishForegroundCriticalSection = (token, reason = 'unspecified') => {
    if (!token || !(globalThis.__manabiForegroundCriticalSectionTokens instanceof Set)) {
        return;
    }
    const didDelete = globalThis.__manabiForegroundCriticalSectionTokens.delete(token);
    globalThis.__manabiForegroundCriticalSectionCount = globalThis.__manabiForegroundCriticalSectionTokens.size;
    if (didDelete) {
        manabiTimelineMark('foregroundCriticalSection.finish', {
            reason,
            token,
            count: globalThis.__manabiForegroundCriticalSectionCount,
        });
        try {
            window.webkit?.messageHandlers?.ebookForegroundCriticalSection?.postMessage({
                phase: 'end',
                reason,
                token,
            });
        } catch (_error) {}
    }
};

const summarizeDocumentFontState = (doc) => ({
    fontStatus: doc?.fonts?.status ?? 'unsupported',
    hasFontsAPI: !!doc?.fonts,
    readyState: doc?.readyState ?? 'nil',
    isCacheWarmerDocument: isCacheWarmerDocument(doc),
});
const classifySingleMediaDocumentForInitialLayout = (doc, reason = 'unknown') => {
    const body = doc?.body;
    if (!body || body.dataset?.mnbSingleMediaInitialLayoutChecked === 'true') {
        return {
            applied: false,
            reason: body ? 'already-checked' : 'missing-body',
        };
    }
    body.dataset.mnbSingleMediaInitialLayoutChecked = 'true';
    if (body.dataset?.mnbHasReaderSegments === 'true') {
        return {
            applied: false,
            reason: 'reader-segments',
        };
    }
    const mediaSelector = 'img, svg, image, picture, video, object';
    const mediaElements = Array.from(body.querySelectorAll?.(mediaSelector) ?? []);
    const textLength = body.textContent?.trim?.().length ?? 0;
    if (textLength > 0 || mediaElements.length !== 1) {
        return {
            applied: false,
            reason: 'not-single-media',
            textLength,
            mediaCount: mediaElements.length,
            substantiveElementCount: null,
        };
    }
    const textNodeType = doc.defaultView?.Node?.TEXT_NODE ?? 3;
    const substantiveElements = Array.from(body.querySelectorAll?.('*') ?? [])
        .filter((element) => {
            if (element?.nodeType !== 1) return false;
            if (element.matches(mediaSelector)) return false;
            if (element.closest('m-m, .mnb-tracking-container')) return false;
            if (element.matches('.h-valign-width, .v-valign-height, .inline-width, .inline-height')) return false;
            const tagName = element.tagName?.toLowerCase?.() ?? '';
            if (tagName === 'br' || tagName === 'script' || tagName === 'style') return false;
            const ownText = Array.from(element.childNodes ?? [])
                .filter((node) => node.nodeType === textNodeType)
                .map((node) => node.textContent ?? '')
                .join('')
                .trim();
            return ownText.length > 0;
        });
    const shouldApply = textLength === 0 && mediaElements.length === 1 && substantiveElements.length === 0;
    if (!shouldApply) {
        return {
            applied: false,
            reason: 'not-single-media',
            textLength,
            mediaCount: mediaElements.length,
            substantiveElementCount: substantiveElements.length,
        };
    }
    const htmlWritingMode = doc.defaultView?.getComputedStyle?.(doc.documentElement)?.writingMode || '';
    const bodyWritingMode = doc.defaultView?.getComputedStyle?.(body)?.writingMode || '';
    if (htmlWritingMode.startsWith('vertical') || bodyWritingMode.startsWith('vertical')) {
        body.classList.add('reader-vertical-writing');
    }
    body.classList.add('reader-is-single-media-element-without-text');
    return {
        applied: true,
        reason: 'single-media',
        textLength,
        mediaCount: mediaElements.length,
        htmlWritingMode,
        bodyWritingMode,
    };
};

const ignoreNextIncomingHideNavigation = (source) => {
    globalThis.__manabiIgnoreNextIncomingHideNavigationCount = 1;
};

const ignoreNextIncomingRevealNavigation = (source) => {
    globalThis.__manabiIgnoreNextIncomingRevealNavigationCount = 1;
};

const postEbookNavigationVisibilityToNative = (shouldHide, source, details = {}) => {
    const requestedHide = !!shouldHide;
    try {
        window.webkit?.messageHandlers?.ebookNavigationVisibility?.postMessage?.({
            hideNavigationDueToScroll: requestedHide,
            source,
            ...details,
        });
        return true;
    } catch (_error) {
        return false;
    }
};

const recordPageTurnNavigationIntent = (direction, source, details = {}) => {
    const now = Date.now();
    if (direction === 'forward') {
        globalThis.__manabiLastForwardPageTurnHideAtMs = now;
    } else if (direction === 'backward') {
        globalThis.__manabiLastBackwardPageTurnRevealAtMs = now;
    }
};

const requestLookupCloseForPageMotion = (reason, details = {}) => {
    if (globalThis.reader?.lookupNavigationPageTurnActive === true) {
        return;
    }
    try {
        window.webkit?.messageHandlers?.touchstartCallbackHandler?.postMessage?.({
            touchedEntryWithElementId: null,
            wasAlreadySelected: false,
            lookupCloseReason: reason,
            touchstartAtMs: Date.now(),
        });
    } catch (_error) {}
};

const resolveFoliatePaginator = (view = null) => {
    const renderer = view?.renderer || null;
    if (renderer?.localName === 'foliate-paginator') return renderer;
    return renderer?.querySelector?.('foliate-paginator')
        || view?.shadowRoot?.querySelector?.('foliate-paginator')
        || null;
};

const getActiveReaderDocument = () => {
    const contents = globalThis.reader?.view?.renderer?.getContents?.() || [];
    return contents[0]?.doc || null;
};

const runWithNavigationIntent = async (intent, operation, { timeoutMs = null } = {}) => {
    const previousIntent = globalThis.__manabiNavigationIntent ?? null;
    globalThis.__manabiNavigationIntent = {
        timestamp: Date.now(),
        ...intent,
    };
    let timeoutHandle = null;
    try {
        const operationPromise = Promise.resolve().then(operation);
        if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
            return await operationPromise;
        }
        const timeoutPromise = new Promise((_, reject) => {
            timeoutHandle = setTimeout(() => {
                reject(new Error(`Timed out after ${timeoutMs}ms`));
            }, timeoutMs);
        });
        return await Promise.race([
            operationPromise,
            timeoutPromise,
        ]);
    } finally {
        if (timeoutHandle !== null) {
            clearTimeout(timeoutHandle);
        }
        globalThis.__manabiNavigationIntent = previousIntent;
    }
};

const getLoadedEbookDocuments = (explicitDoc = null) => {
    const docs = [];
    const addDoc = (doc) => {
        if (!doc || doc === document || docs.includes(doc)) return;
        docs.push(doc);
    };
    addDoc(explicitDoc);
    try {
        const contents = globalThis.reader?.view?.renderer?.getContents?.() || [];
        for (const content of contents) {
            addDoc(content?.doc ?? content?.document ?? null);
        }
    } catch {}
    return docs;
};

const applyNavigationHiddenVisualStateToEbookBody = (body, hidden, options = {}) => {
    if (!body?.style) return false;
    const reason = typeof options?.reason === 'string' ? options.reason : 'unknown';
    const refreshPaint = options?.refreshPaint !== false;
    const isPageTurnNavigationState = reason.includes('page-turn') || reason.includes('relocate.page');
    const previousHidden = typeof body.__manabiNavigationHiddenDueToScroll === 'boolean'
        ? body.__manabiNavigationHiddenDueToScroll
        : null;
    const nextHidden = !!hidden;
    let changed = previousHidden !== nextHidden;
    if (isPageTurnNavigationState && previousHidden !== null && previousHidden !== nextHidden) {
        body.__manabiPendingEbookNavigationTransition = {
            fromHidden: previousHidden,
            toHidden: nextHidden,
            reason,
        };
    }
    body.__manabiPreviousNavigationHiddenDueToScroll = previousHidden ?? nextHidden;
    body.__manabiNavigationHiddenDueToScroll = nextHidden;
    // Keep bookkeeping on the body object rather than in attributes or classes.
    // Either DOM mutation makes WebKit reconsider broad body selectors across the
    // whole chapter; only visible painted segments need the visual state.
    for (const className of ['nav-hidden', 'nav-hidden-due-to-scroll']) {
        if (body.classList?.contains?.(className)) {
            body.classList?.remove?.(className);
            changed = true;
        }
    }
    // Do not drive ebook highlight dimming by changing inherited custom
    // properties on the chapter body. Those variables are referenced by many
    // segment gradients and make WebKit recalculate styles across the whole
    // section on every page turn. Clear old values from previous builds, but
    // keep steady-state page-turn updates local to visible painted segments.
    for (const property of [
        '--mnb-highlight-fill-opacity',
        '--mnb-tracking-highlight-alpha',
        '--mnb-jlpt-underline-alpha',
        '--mnb-overlay-opacity',
        '--mnb-tracking-highlight-opacity',
    ]) {
        if (body.style.getPropertyValue(property)) {
            body.style.removeProperty(property);
            changed = true;
        }
    }
    let refreshResult = null;
    if (refreshPaint) {
        try {
            refreshResult = body.ownerDocument?.defaultView?.manabi_refreshEbookTrackingPaintNavigationState?.(hidden, {
                source: reason,
            });
            if (refreshResult?.mutatedCount > 0) {
                changed = true;
            }
        } catch (_error) {}
    }
    if (!isPageTurnNavigationState) {
        body.__manabiPreviousNavigationHiddenDueToScroll = nextHidden;
    }
    return changed;
};

const applyNavigationHiddenStateToEbookDocument = (doc, reason = 'unknown') => {
    const body = doc?.body;
    if (!body || doc === document) {
        return {
            applied: false,
            reason: body ? 'outer-document' : 'missing-body',
        };
    }
    const hidden = globalThis.reader?.navHUD?.hideNavigationDueToScroll === true;
    const changed = applyNavigationHiddenVisualStateToEbookBody(body, hidden, { reason });
    return {
        applied: true,
        hidden,
        changed,
        mode: 'visual-vars',
    };
};

window.manabiApplyNavigationHiddenStateToEbookDocument = (reason = 'manual', explicitDoc = null) => {
    const docs = getLoadedEbookDocuments(explicitDoc);
    let appliedCount = 0;
    for (const doc of docs) {
        if (applyNavigationHiddenStateToEbookDocument(doc, reason).applied) {
            appliedCount += 1;
        }
    }
    return {
        documentCount: docs.length,
        appliedCount,
    };
};

const copyCustomReaderFontStyleToDocument = (sourceFontStyle, doc, reason = 'unknown') => {
    if (!doc || doc === document) return false;
    if (!sourceFontStyle) {
        return false;
    }
    let targetFontStyle = doc.getElementById('mnb-custom-fonts-inline');
    const sourceTag = sourceFontStyle.tagName?.toLowerCase();
    const desiredTag = sourceTag === 'link' ? 'link' : 'style';
    if (targetFontStyle && targetFontStyle.tagName?.toLowerCase() !== desiredTag) {
        targetFontStyle.remove();
        targetFontStyle = null;
    }
    if (!targetFontStyle) {
        targetFontStyle = doc.createElement(desiredTag);
        targetFontStyle.id = 'mnb-custom-fonts-inline';
        (doc.head || doc.documentElement).appendChild(targetFontStyle);
    }
    let changed = false;
    const writingDirection = doc.body?.dataset?.mnbWritingDirection
        || doc.body?.dataset?.mnbFoliateWritingDirection
        || null;
    const isVerticalDocument = writingDirection === 'vertical'
        || doc.body?.classList?.contains?.('reader-vertical-writing') === true;
    const directionalFamily = isVerticalDocument
        ? (globalThis.manabiVerticalFontFamilyName || sourceFontStyle.dataset?.mnbInjectedFontFamily)
        : (globalThis.manabiHorizontalFontFamilyName || sourceFontStyle.dataset?.mnbInjectedFontFamily);
    if (desiredTag === 'link') {
        const nextRel = sourceFontStyle.rel || 'stylesheet';
        // Local reader-font stylesheets define both directional aliases. Reuse
        // the source URL so changing writing direction does not reload CSS.
        const nextHref = sourceFontStyle.href;
        if (targetFontStyle.rel !== nextRel) {
            targetFontStyle.rel = nextRel;
            changed = true;
        }
        if (targetFontStyle.href !== nextHref) {
            targetFontStyle.href = nextHref;
            changed = true;
        }
    } else {
        const nextText = sourceFontStyle.textContent || '';
        if (targetFontStyle.textContent !== nextText) {
            targetFontStyle.textContent = nextText;
            changed = true;
        }
    }
    for (const [key, value] of Object.entries(sourceFontStyle.dataset || {})) {
        const nextValue = key === 'mnbInjectedFontFamily' && directionalFamily
            ? directionalFamily
            : value;
        if (targetFontStyle.dataset[key] !== nextValue) {
            targetFontStyle.dataset[key] = nextValue;
            changed = true;
        }
    }
    if (doc.documentElement && directionalFamily) {
        const nextFamily = directionalFamily;
        if (doc.documentElement.dataset.mnbInjectedFontFamily !== nextFamily) {
            doc.documentElement.dataset.mnbInjectedFontFamily = nextFamily;
            changed = true;
        }
        if (doc.documentElement.dataset.mnbFontInjected !== '1') {
            doc.documentElement.dataset.mnbFontInjected = '1';
            changed = true;
        }
    }
    return changed;
};

window.manabiForwardReaderFontToEbookDocuments = (reason = 'manual', explicitDoc = null) => {
    const docs = getLoadedEbookDocuments(explicitDoc);
    const sourceFontStyle = document.getElementById('mnb-custom-fonts-inline')
        || docs.map((doc) => doc?.getElementById?.('mnb-custom-fonts-inline')).find(Boolean)
        || null;
    let forwardedCount = 0;
    for (const doc of docs) {
        if (copyCustomReaderFontStyleToDocument(sourceFontStyle, doc, reason)) {
            forwardedCount += 1;
        }
    }
    return {
        documentCount: docs.length,
        forwardedCount,
        outerHasCustomFontStyle: !!sourceFontStyle,
    };
};

const normalizeReaderPresentationState = (settings = null) => {
    if (!settings || typeof settings !== 'object') return null;
    const colorScheme = settings.colorScheme === 'dark' || settings.colorScheme === 'light'
        ? settings.colorScheme
        : null;
    const readerFontSize = Number(settings.readerFontSize);
    const resolvedFontSize = Number.isFinite(readerFontSize) && readerFontSize > 0
        ? readerFontSize
        : null;
    const readerContentRTSize = Number(settings.readerContentRTSize);
    const resolvedRTSize = Number.isFinite(readerContentRTSize) && readerContentRTSize > 0
        ? readerContentRTSize
        : (resolvedFontSize ? resolvedFontSize * 0.46 : null);
    const lightModeTheme = typeof settings.lightModeTheme === 'string' && settings.lightModeTheme.length > 0
        ? settings.lightModeTheme
        : null;
    const darkModeTheme = typeof settings.darkModeTheme === 'string' && settings.darkModeTheme.length > 0
        ? settings.darkModeTheme
        : null;
    const maxWidthOverride = typeof settings.maxWidthOverride === 'string' && settings.maxWidthOverride.length > 0
        ? settings.maxWidthOverride
        : null;
    const writingDirection = 'original';
    return {
        colorScheme,
        lightModeTheme,
        darkModeTheme,
        readerFontSize: resolvedFontSize,
        readerContentRTSize: resolvedRTSize,
        readerFontSizeCSS: resolvedFontSize ? `${resolvedFontSize}px` : null,
        readerContentRTSizeCSS: resolvedRTSize ? `${resolvedRTSize}px` : null,
        readerBoldText: settings.readerBoldText === true,
        maxWidthOverride,
        writingDirection,
    };
};

const applyReaderPresentationStateToDocument = (doc, settings, reason = 'unknown') => {
    const normalized = normalizeReaderPresentationState(settings);
    const body = doc?.body;
    if (!normalized || !body) return false;
    const root = doc.documentElement;
    const signature = JSON.stringify(normalized);
    if (body.dataset.mnbReaderPresentationStateSignature === signature) {
        return false;
    }
    if (normalized.colorScheme) {
        body.dataset.mnbColorScheme = normalized.colorScheme;
        root?.style?.setProperty?.('color-scheme', normalized.colorScheme);
        body.style?.setProperty?.('color-scheme', normalized.colorScheme);
    }
    if (normalized.lightModeTheme) {
        body.dataset.mnbLightTheme = normalized.lightModeTheme;
    }
    if (normalized.darkModeTheme) {
        body.dataset.mnbDarkTheme = normalized.darkModeTheme;
    }
    if (normalized.readerFontSizeCSS) {
        body.style.setProperty('font-size', normalized.readerFontSizeCSS);
        body.style.setProperty('--mnb-reader-content-font-size', normalized.readerFontSizeCSS);
        root?.style?.setProperty?.('--mnb-reader-content-font-size', normalized.readerFontSizeCSS);
    }
    if (normalized.readerContentRTSizeCSS) {
        body.style.setProperty('--mnb-reader-content-rt-size', normalized.readerContentRTSizeCSS);
        root?.style?.setProperty?.('--mnb-reader-content-rt-size', normalized.readerContentRTSizeCSS);
    }
    if (normalized.readerBoldText) {
        body.style.setProperty('font-weight', '600');
    } else {
        body.style.removeProperty('font-weight');
    }
    if (normalized.maxWidthOverride) {
        body.style.setProperty('--mnb-reader-max-width-override', normalized.maxWidthOverride);
        root?.style?.setProperty?.('--mnb-reader-max-width-override', normalized.maxWidthOverride);
    }
    body.dataset.mnbReaderPresentationStateSignature = signature;
    body.dataset.mnbReaderPresentationStateReason = reason;
    return true;
};

// Processed EPUB HTML is cached independently of user preferences. Copy only
// geometry-affecting text settings before Foliate columnizes the child. Paint
// and UI settings stay with the later native refresh because some have
// imperative side effects beyond updating their dataset value.
const ebookLayoutSettingDatasetKeys = Object.freeze([
    'mnbFuriganaEnabled',
    'mnbFuriganaOriginalOnly',
    'mnbRomajiModeEnabled',
    'mnbFamiliarFuriganaEnabled',
    'mnbLearningFuriganaEnabled',
    'mnbKnownFuriganaEnabled',
]);

const applyLayoutSettingsToEbookDocument = (doc) => {
    const sourceDataset = document.body?.dataset;
    const targetDataset = doc?.body?.dataset;
    if (!sourceDataset || !targetDataset || doc === document) {
        return false;
    }
    let changed = false;
    for (const key of ebookLayoutSettingDatasetKeys) {
        const value = sourceDataset[key];
        if (value === undefined || targetDataset[key] === value) {
            continue;
        }
        targetDataset[key] = value;
        changed = true;
    }
    return changed;
};

const installReaderPresentationState = (settings = null, reason = 'unknown') => {
    const normalized = normalizeReaderPresentationState(settings);
    if (!normalized) return null;
    globalThis.__manabiReaderPresentationState = normalized;
    if (normalized.colorScheme) globalThis.manabiReaderColorScheme = normalized.colorScheme;
    if (normalized.lightModeTheme) globalThis.manabiReaderLightModeTheme = normalized.lightModeTheme;
    if (normalized.darkModeTheme) globalThis.manabiReaderDarkModeTheme = normalized.darkModeTheme;
    if (normalized.readerFontSizeCSS) globalThis.manabiReaderFontSizeCSS = normalized.readerFontSizeCSS;
    if (normalized.maxWidthOverride) globalThis.manabiReaderMaxWidthOverride = normalized.maxWidthOverride;
    if (normalized.writingDirection) globalThis.__manabiEbookViewerWritingDirection = normalized.writingDirection;
    const applied = applyReaderPresentationStateToDocument(document, normalized, reason);
    return normalized;
};

const liveProcessedSectionHrefSet = () => {
    if (!(globalThis.__manabiLiveProcessedSectionHrefs instanceof Set)) {
        globalThis.__manabiLiveProcessedSectionHrefs = new Set();
    }
    return globalThis.__manabiLiveProcessedSectionHrefs;
};

const liveSettledSectionHrefSet = () => {
    if (!(globalThis.__manabiLiveSettledSectionHrefs instanceof Set)) {
        globalThis.__manabiLiveSettledSectionHrefs = new Set();
    }
    return globalThis.__manabiLiveSettledSectionHrefs;
};

const firstLiveSectionHref = () => {
    const normalizedHref = normalizeSpineHref(globalThis.__manabiFirstLiveSectionHref ?? null);
    return normalizedHref || null;
};

window.manabi_recordLiveProcessedSection = (href) => {
    const normalizedHref = normalizeSpineHref(href);
    if (!normalizedHref) return;
    const processedSet = liveProcessedSectionHrefSet();
    processedSet.add(normalizedHref);
    if (globalThis.__manabiInitialForegroundNextSectionPending && processedSet.size >= 2) {
        globalThis.__manabiInitialForegroundNextSectionPending = false;
    }
};

window.manabi_recordLiveSettledSection = (href) => {
    const normalizedHref = normalizeSpineHref(href);
    if (!normalizedHref) return;
    const settledSet = liveSettledSectionHrefSet();
    settledSet.add(normalizedHref);
};

window.manabi_syncLiveSettledSections = (payload = {}) => {
    const rawHrefs =
        (Array.isArray(payload.hrefs) && payload.hrefs)
        || (Array.isArray(payload.settledSectionHrefs) && payload.settledSectionHrefs)
        || [];
    const nextSettledSectionHrefs = Array.from(new Set(
        rawHrefs.map((href) => normalizeSpineHref(href)).filter(Boolean)
    )).sort();
    globalThis.__manabiLiveProcessedSectionHrefs = new Set(nextSettledSectionHrefs);
    if (typeof payload.firstLiveHref === 'string' && payload.firstLiveHref.length > 0) {
        globalThis.__manabiFirstLiveSectionHref = normalizeSpineHref(payload.firstLiveHref);
    }
};

const postOpenReaderGoToSheetRequest = (source, targetID = null, options = {}) => {
    const preserveHiddenNavigation = !!options.preserveHiddenNavigation;
    const preserveVisibleNavigation = !!options.preserveVisibleNavigation;
    try {
        window.webkit?.messageHandlers?.openReaderGoToSheet?.postMessage?.({
            source,
            targetID,
            preserveHiddenNavigation,
            preserveVisibleNavigation,
        });
    } catch (error) {
    }
};

const flattenTOCEntries = (items, collector = []) => {
    if (!Array.isArray(items)) {
        return collector;
    }
    for (const item of items) {
        if (!item) {
            continue;
        }
        collector.push(item);
        if (Array.isArray(item.subitems) && item.subitems.length > 0) {
            flattenTOCEntries(item.subitems, collector);
        }
    }
    return collector;
};

const fallbackSectionTitle = (href, index) => {
    if (typeof href === 'string' && href) {
        const lastSegment = href.split('/').pop() || href;
        const withoutExtension = lastSegment.replace(/\.[^/.]+$/, '');
        if (/^title$/i.test(withoutExtension)) {
            return 'Title Page';
        }
        const prettified = withoutExtension
            .replace(/[_-]+/g, ' ')
            .replace(/\s+/g, ' ')
            .trim();
        if (prettified && !/^\d+$/.test(prettified)) {
            return prettified.replace(/\b\w/g, (char) => char.toUpperCase());
        }
    }
    return `Section ${index + 1}`;
};

const isLikelyMetadataSectionHref = (href) => {
    if (typeof href !== 'string' || !href) {
        return false;
    }
    const lastSegment = href.split('/').pop() || href;
    const withoutExtension = lastSegment.replace(/\.[^/.]+$/, '').trim();
    return /^(title|cover|nav|toc|contents?)$/i.test(withoutExtension);
};

const buildLinearSectionEntries = (book) => {
    const tocEntries = flattenTOCEntries(book?.toc ?? []);
    const tocTitleByHref = new Map();
    for (const entry of tocEntries) {
        const href = typeof entry?.href === 'string' ? entry.href : null;
        const title = typeof entry?.label === 'string' ? entry.label.trim() : '';
        if (!href || !title || tocTitleByHref.has(href)) {
            continue;
        }
        tocTitleByHref.set(href, title);
    }
    const sectionEntries = Array.isArray(book?.sections)
        ? book.sections
            .filter((section) => section && section.linear !== 'no')
            .map((section, index) => {
                const href = typeof section?.id === 'string' ? section.id : null;
                const title = href ? (tocTitleByHref.get(href) ?? fallbackSectionTitle(href, index)) : '';
                return href && title
                    ? {
                        href,
                        title,
                        pageNumber: null,
                    }
                    : null;
            })
            .filter(Boolean)
        : [];
    const contentSectionEntries = sectionEntries.filter(function(entry) { return !isLikelyMetadataSectionHref(entry?.href); });
    if (contentSectionEntries.length === 1) {
        const onlyContentSection = contentSectionEntries[0];
        if (onlyContentSection && /^Section \d+$/i.test(onlyContentSection.title)) {
            onlyContentSection.title = 'Main Content';
        }
    }
    return sectionEntries;
};

const buildLinearSectionStartPercentByHref = (book) => {
    const linearSections = Array.isArray(book?.sections)
        ? book.sections.filter((section) => section && section.linear !== 'no')
        : [];
    const totalSize = linearSections.reduce((sum, section) => {
        const size = Number(section?.size);
        return sum + (Number.isFinite(size) && size > 0 ? size : 0);
    }, 0);
    const startPercentByHref = new Map();
    let consumedSize = 0;
    for (const section of linearSections) {
        const href = typeof section?.id === 'string' ? section.id : null;
        const normalizedHref = normalizeSpineHref(href);
        if (normalizedHref != null && !startPercentByHref.has(normalizedHref)) {
            const fraction = totalSize > 0 ? consumedSize / totalSize : 0;
            startPercentByHref.set(normalizedHref, safeRound(Math.max(0, Math.min(1, fraction)) * 100, 1));
        }
        const size = Number(section?.size);
        if (Number.isFinite(size) && size > 0) {
            consumedSize += size;
        }
    }
    return startPercentByHref;
};

const buildGoToSnapshotChapters = (book) => {
    const chapters = [];
    const seenHrefs = new Set();
    const tocEntries = flattenTOCEntries(book?.toc ?? []);
    for (const entry of tocEntries) {
        const href = typeof entry?.href === 'string' ? entry.href : null;
        const title = typeof entry?.label === 'string' ? entry.label.trim() : '';
        if (!href || !title || seenHrefs.has(href)) {
            continue;
        }
        seenHrefs.add(href);
        chapters.push({
            href,
            title,
            pageNumber: null,
        });
    }
    const sectionEntries = buildLinearSectionEntries(book);
    for (const entry of sectionEntries) {
        if (!entry?.href || !entry?.title || seenHrefs.has(entry.href)) {
            continue;
        }
        seenHrefs.add(entry.href);
        chapters.push(entry);
    }
    return chapters;
};

const normalizeSpineHref = (href) => {
    if (typeof href !== 'string') return null;
    const trimmed = href.trim();
    if (!trimmed) return null;
    const hashIndex = trimmed.indexOf('#');
    return hashIndex >= 0 ? trimmed.slice(0, hashIndex) : trimmed;
};

const injectBodyDatasetAttributes = (html, attributes) => {
    if (typeof html !== 'string' || !html.replace) {
        return html;
    }
    const entries = Object.entries(attributes)
        .filter(([, value]) => value !== undefined && value !== null && value !== '')
    if (entries.length === 0) {
        return html;
    }
    const escapeAttributeValue = (value) => String(value)
        .replace(/&/g, '&amp;')
        .replace(/"/g, '&quot;')
        .replace(/</g, '&lt;');
    const bodyTagMatch = html.match(/<body\b[^>]*>/i);
    if (!bodyTagMatch) {
        return html;
    }
    let bodyTag = bodyTagMatch[0];
    for (const [key, value] of entries) {
        const escapedValue = escapeAttributeValue(value);
        const attributePattern = new RegExp(`\\s${key}(?:\\s*=\\s*(?:"[^"]*"|'[^']*'|[^\\s>]*))?`, 'ig');
        bodyTag = bodyTag.replace(attributePattern, '');
        bodyTag = bodyTag.replace(/>$/, ` ${key}="${escapedValue}">`);
    }
    return html.slice(0, bodyTagMatch.index) + bodyTag + html.slice(bodyTagMatch.index + bodyTagMatch[0].length);
};

const setNativeHideNavigationState = (shouldHide, source = 'native-bridge') => {
    const sequence = (globalThis.__manabiNativeBridgeVisibilitySequence = Number(globalThis.__manabiNativeBridgeVisibilitySequence || 0) + 1);
    const normalized = !!shouldHide;
    const body = document.body;
    const before = captureNavVisibilityState();
    if (body?.classList?.contains?.('nav-hidden')) {
        body.classList.remove('nav-hidden');
    }
    globalThis.reader?.navHUD?.setHideNavigationDueToScroll?.(normalized, source, {
        bridgeSource: source,
        bodyClassApplied: false,
    });
    const afterSetHide = captureNavVisibilityState();
    const bridgeState = {
        sequence,
        source,
        shouldHide: normalized,
        beforeHudHideNavigationDueToScroll: before.hudHideNavigationDueToScroll ?? null,
        beforeLabelVariant: before.labelVariant ?? null,
        ...captureNavVisibilityState(),
    };
    return normalized;
};

window.manabiSetHideNavigationDueToScroll = (shouldHide, source = 'window.manabiSetHideNavigationDueToScroll') => {
    const requestedHide = !!shouldHide;
    if (requestedHide) {
        const ignoreCount = Number(globalThis.__manabiIgnoreNextIncomingHideNavigationCount || 0);
        if (ignoreCount > 0) {
            globalThis.__manabiIgnoreNextIncomingHideNavigationCount = ignoreCount - 1;
            return false;
        }
    } else {
        const now = Date.now();
        if (
            source === 'touchstartCallbackHandler.noElement.nativeToggle'
            || source?.startsWith?.('explicitReveal.')
        ) {
            globalThis.__manabiLastExplicitNavigationRevealAtMs = now;
        }
        const lastForwardPageTurnHideAtMs = Number(globalThis.__manabiLastForwardPageTurnHideAtMs || 0);
        const lastBackwardPageTurnRevealAtMs = Number(globalThis.__manabiLastBackwardPageTurnRevealAtMs || 0);
        const isStaleSwiftRevealAfterForwardPageTurn =
            source === 'swift.bindingPush'
            && lastForwardPageTurnHideAtMs > lastBackwardPageTurnRevealAtMs
            && now - lastForwardPageTurnHideAtMs < 1500
            && globalThis.reader?.navHUD?.hideNavigationDueToScroll === true;
        if (isStaleSwiftRevealAfterForwardPageTurn) {
            return true;
        }
        if (globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay === true) {
            return true;
        }
        const ignoreCount = Number(globalThis.__manabiIgnoreNextIncomingRevealNavigationCount || 0);
        if (ignoreCount > 0) {
            globalThis.__manabiIgnoreNextIncomingRevealNavigationCount = ignoreCount - 1;
            return true;
        }
    }
    const result = setNativeHideNavigationState(requestedHide, source);
    return result;
};

const isCompactNavigationSheetSidePaginationDisabled = () => {
    const detentKind = document.body?.dataset?.mnbCompactNavigationSheetDetentKind;
    // Compact ebook chrome reserves bottom space but does not cover the side page-turn chevrons.
    // Larger sheet states can cover reader content, so they still suppress side pagination.
    return document.body?.dataset?.mnbCompactNavigationSheetPresentedAsSheet === 'true'
        && detentKind !== 'zero'
        && detentKind !== 'compact'
        && detentKind !== 'compactMedia';
};

window.manabiSetCompactNavigationSheetDetentState = (state = {}) => {
    const presentedAsSheet = state?.presentedAsSheet === true || state?.presentedAsSheet === 'true';
    const semanticDetentKind = typeof state?.semanticDetentKind === 'string'
        ? state.semanticDetentKind
        : 'unknown';
    document.body.dataset.mnbCompactNavigationSheetPresentedAsSheet = presentedAsSheet ? 'true' : 'false';
    document.body.dataset.mnbCompactNavigationSheetDetentKind = semanticDetentKind;
    const sidePaginationDisabled = isCompactNavigationSheetSidePaginationDisabled();
    document.body.dataset.mnbCompactNavigationSheetSidePaginationDisabled = sidePaginationDisabled ? 'true' : 'false';
    void globalThis.reader?.updateNavButtons?.();
    return {
        presentedAsSheet,
        semanticDetentKind,
        sidePaginationDisabled,
    };
};

const normalizeChromeInsetCSSValue = (value) => {
    if (typeof value === 'number' && Number.isFinite(value)) {
        return `${value}px`;
    }
    if (typeof value === 'string') {
        const trimmed = value.trim();
        return trimmed.length > 0 ? trimmed : '0px';
    }
    return '0px';
};

const parseChromeInsetPixelValue = (value) => {
    if (typeof value === 'number' && Number.isFinite(value)) {
        return value;
    }
    if (typeof value !== 'string') {
        return Number.NEGATIVE_INFINITY;
    }
    const trimmed = value.trim();
    if (trimmed.length === 0) {
        return Number.NEGATIVE_INFINITY;
    }
    const numeric = Number.parseFloat(trimmed);
    return Number.isFinite(numeric) ? numeric : Number.NEGATIVE_INFINITY;
};

const createDefaultChromeInsetState = () => ({
    obscuredTopInset: '0px',
    toolbarBottomOffset: '0px',
    obscuredBottomInset: '0px',
    source: 'default',
    revision: 0,
});

const normalizeChromeInsetState = (rawState, fallbackSource = 'unknown') => {
    const normalizedState = {
        obscuredTopInset: normalizeChromeInsetCSSValue(rawState?.obscuredTopInset),
        toolbarBottomOffset: normalizeChromeInsetCSSValue(rawState?.toolbarBottomOffset),
        obscuredBottomInset: normalizeChromeInsetCSSValue(rawState?.obscuredBottomInset),
        source: typeof rawState?.source === 'string' && rawState.source.trim().length > 0
            ? rawState.source.trim()
            : fallbackSource,
        revision: Number.isFinite(rawState?.revision)
            ? rawState.revision
            : null,
    };
    return normalizedState;
};

const getStoredChromeInsetState = () =>
    normalizeChromeInsetState(globalThis.__swiftUIWebViewObscuredInsets, 'stored');

const readChromeInsetStateFromWindow = (targetWindow, fallbackSource) => {
    try {
        if (!targetWindow) return null;
        return normalizeChromeInsetState(targetWindow.__swiftUIWebViewObscuredInsets, fallbackSource);
    } catch {
        return null;
    }
};

const readLastPositiveChromeInsetStateFromWindow = (targetWindow, fallbackSource) => {
    try {
        if (!targetWindow) return null;
        return normalizeChromeInsetState(targetWindow.__manabiLastPositiveChromeInsets, fallbackSource);
    } catch {
        return null;
    }
};

const getAncestorChromeInsetState = () => {
    const candidates = [];
    try {
        if (window.parent && window.parent !== window) {
            candidates.push(readChromeInsetStateFromWindow(window.parent, 'parent-stored'));
            candidates.push(readLastPositiveChromeInsetStateFromWindow(window.parent, 'parent-stored-positive'));
        }
    } catch {}
    try {
        if (window.top && window.top !== window.parent && window.top !== window) {
            candidates.push(readChromeInsetStateFromWindow(window.top, 'top-stored'));
            candidates.push(readLastPositiveChromeInsetStateFromWindow(window.top, 'top-stored-positive'));
        }
    } catch {}
    for (const candidate of candidates.filter(Boolean)) {
        if (
            parseChromeInsetPixelValue(candidate.obscuredTopInset) > 0 ||
            parseChromeInsetPixelValue(candidate.toolbarBottomOffset) > 0 ||
            parseChromeInsetPixelValue(candidate.obscuredBottomInset) > 0
        ) {
            return candidate;
        }
    }
    return null;
};

const getStoredPositiveChromeInsetState = () => {
    const currentState = getStoredChromeInsetState();
    if (
        parseChromeInsetPixelValue(currentState.obscuredTopInset) > 0 ||
        parseChromeInsetPixelValue(currentState.toolbarBottomOffset) > 0 ||
        parseChromeInsetPixelValue(currentState.obscuredBottomInset) > 0
    ) {
        return currentState;
    }
    const localPositiveState = normalizeChromeInsetState(globalThis.__manabiLastPositiveChromeInsets, 'stored-positive');
    if (
        parseChromeInsetPixelValue(localPositiveState.obscuredTopInset) > 0 ||
        parseChromeInsetPixelValue(localPositiveState.toolbarBottomOffset) > 0 ||
        parseChromeInsetPixelValue(localPositiveState.obscuredBottomInset) > 0
    ) {
        return localPositiveState;
    }
    return getAncestorChromeInsetState()
        ?? localPositiveState;
};

const getNextChromeInsetRevision = () => {
    const currentRevision = Number.isFinite(globalThis.__swiftUIWebViewObscuredInsetsRevision)
        ? globalThis.__swiftUIWebViewObscuredInsetsRevision
        : 0;
    const nextRevision = currentRevision + 1;
    globalThis.__swiftUIWebViewObscuredInsetsRevision = nextRevision;
    return nextRevision;
};

const applyResolvedChromeInsetState = (state) => {
    for (const target of [document.documentElement, document.body].filter(Boolean)) {
        target.style.setProperty('--mnb-reader-stage-top-inset', state.obscuredTopInset);
        target.style.setProperty('--mnb-toolbar-bottom-offset', state.toolbarBottomOffset);
    }
    const readerStage = document.getElementById('reader-stage');
    if (readerStage) {
        readerStage.style.top = state.obscuredTopInset;
        readerStage.style.bottom = 'var(--mnb-reader-stage-bottom-inset, 0px)';
    }
};

const formatLandscapeInsetRect = (rect) => {
    if (!rect) return null;
    return {
        x: Math.round(rect.x),
        y: Math.round(rect.y),
        width: Math.round(rect.width),
        height: Math.round(rect.height),
        top: Math.round(rect.top),
        bottom: Math.round(rect.bottom),
    };
};

const captureLandscapeInsetLayoutProbe = () => {
    const liveFoliateView = Array.from(document.querySelectorAll('foliate-view'))
        .find((view) => view?.dataset?.isCache !== 'true') || null;
    const livePaginator = resolveFoliatePaginator(liveFoliateView);
    const livePaginatorContainer = livePaginator?.shadowRoot?.getElementById?.('container') || null;
    const htmlStyle = getComputedStyle(document.documentElement);
    const bodyStyle = document.body ? getComputedStyle(document.body) : null;
    const navBar = document.getElementById('nav-bar');
    const readerStage = document.getElementById('reader-stage');
    const navBarRect = navBar?.getBoundingClientRect?.() ?? null;
    const readerStageRect = readerStage?.getBoundingClientRect?.() ?? null;
    const visibleFrame = Array.from(livePaginator?.shadowRoot?.querySelectorAll?.('iframe') ?? []).find((frame) => {
        const rect = frame?.getBoundingClientRect?.();
        return rect && rect.width > 0 && rect.height > 0;
    }) ?? null;
    let iframeBodyRect = null;
    try {
        const frameRect = visibleFrame?.getBoundingClientRect?.() ?? null;
        const bodyRect = visibleFrame?.contentDocument?.body?.getBoundingClientRect?.() ?? null;
        if (frameRect && bodyRect) {
            iframeBodyRect = {
                x: frameRect.left + bodyRect.left,
                y: frameRect.top + bodyRect.top,
                width: bodyRect.width,
                height: bodyRect.height,
                top: frameRect.top + bodyRect.top,
                bottom: frameRect.top + bodyRect.bottom,
            };
        }
    } catch {}
    return {
        windowInner: `${window.innerWidth ?? 0}x${window.innerHeight ?? 0}`,
        visualViewport: window.visualViewport ? `${Math.round(window.visualViewport.width)}x${Math.round(window.visualViewport.height)}` : null,
        bodyCssToolbarBottom: bodyStyle?.getPropertyValue('--mnb-toolbar-bottom-offset')?.trim() || null,
        bodyCssSystemBottom: bodyStyle?.getPropertyValue('--mnb-system-bottom-inset')?.trim() || null,
        bodyCssToolbarPhysicalBottom: bodyStyle?.getPropertyValue('--mnb-toolbar-physical-bottom-inset')?.trim() || null,
        bodyCssToolbarLayoutBottom: bodyStyle?.getPropertyValue('--mnb-toolbar-layout-bottom-inset')?.trim() || null,
        bodyCssStageBottom: bodyStyle?.getPropertyValue('--mnb-reader-stage-bottom-inset')?.trim() || null,
        readyState: document.readyState ?? null,
        bodyLoading: !!document.body?.classList?.contains?.('loading'),
        hasLiveFoliateView: !!liveFoliateView,
        hasLivePaginator: !!livePaginator,
        navBarRect: formatLandscapeInsetRect(navBarRect),
        readerStageRect: formatLandscapeInsetRect(readerStageRect),
        navBarBottomGapToViewport: Number.isFinite(navBarRect?.bottom)
            ? Math.round(((window.visualViewport?.height ?? window.innerHeight ?? 0) - navBarRect.bottom) * 10) / 10
            : null,
        readerStageBottomGapToViewport: Number.isFinite(readerStageRect?.bottom)
            ? Math.round(((window.visualViewport?.height ?? window.innerHeight ?? 0) - readerStageRect.bottom) * 10) / 10
            : null,
        foliateViewRect: formatLandscapeInsetRect(liveFoliateView?.getBoundingClientRect?.() ?? null),
        paginatorRect: formatLandscapeInsetRect(livePaginator?.getBoundingClientRect?.() ?? null),
        paginatorContainer: livePaginatorContainer ? `${livePaginatorContainer.clientWidth}x${livePaginatorContainer.clientHeight}` : null,
        iframeRect: formatLandscapeInsetRect(visibleFrame?.getBoundingClientRect?.() ?? null),
        iframeBodyRect: iframeBodyRect ? formatLandscapeInsetRect(iframeBodyRect) : null,
    };
};

const postLandscapeInsetRestoreProbe = (stage, restoreState = null, extra = {}) => {
    try {
        const payload = {
            stage: 'ebookChromeInsets.restoreGeometry',
            restoreStage: stage,
            requestedRestoreFraction: Number.isFinite(globalThis.__manabiRequestedRestoreFraction)
                ? safeRound(globalThis.__manabiRequestedRestoreFraction, 6)
                : null,
            landedFraction: typeof restoreState?.currentFraction === 'number'
                ? safeRound(restoreState.currentFraction, 6)
                : null,
            landedSectionIndex: restoreState?.sectionIndex ?? null,
            landedLocationCurrent: restoreState?.locationCurrent ?? null,
            landedLocationTotal: restoreState?.locationTotal ?? null,
            ...extra,
            layout: captureLandscapeInsetLayoutProbe(),
        };
        const key = JSON.stringify(payload);
        if (globalThis.__manabiLastLandscapeInsetRestoreProbeKey !== key) {
            globalThis.__manabiLastLandscapeInsetRestoreProbeKey = key;
        }
    } catch {}
};

const scheduleReaderUIChromeInsetSettle = (reason, state) => {
    const signature = JSON.stringify({
        reason,
        obscuredTopInset: state?.obscuredTopInset ?? null,
        toolbarBottomOffset: state?.toolbarBottomOffset ?? null,
        obscuredBottomInset: state?.obscuredBottomInset ?? null,
        revision: state?.revision ?? null,
    });
    if (globalThis.__manabiLastReaderUIChromeSettleSignature === signature) {
        return;
    }
    globalThis.__manabiLastReaderUIChromeSettleSignature = signature;
};

const applyStoredChromeInsets = (reason = 'unknown', incomingState = null) => {
    if (MANABI_DISABLE_DYNAMIC_CHROME_INSETS) {
        const nextState = {
            ...createDefaultChromeInsetState(),
            source: `${reason}:disabled`,
            revision: Number.isFinite(globalThis.__swiftUIWebViewObscuredInsetsRevision)
                ? globalThis.__swiftUIWebViewObscuredInsetsRevision
                : 0,
        };
        globalThis.__swiftUIWebViewObscuredInsets = nextState;
        applyResolvedChromeInsetState(nextState);
        return nextState;
    }

    const previousState = getStoredChromeInsetState();
    const storedPositiveState = getStoredPositiveChromeInsetState();
    const ancestorPositiveState = getAncestorChromeInsetState();
    let nextState = incomingState
        ? normalizeChromeInsetState(incomingState, reason)
        : previousState;

    if (!Number.isFinite(nextState.revision)) {
        nextState.revision = incomingState ? getNextChromeInsetRevision() : previousState.revision;
    } else {
        globalThis.__swiftUIWebViewObscuredInsetsRevision = Math.max(
            Number.isFinite(globalThis.__swiftUIWebViewObscuredInsetsRevision) ? globalThis.__swiftUIWebViewObscuredInsetsRevision : 0,
            nextState.revision,
        );
    }

    if (!incomingState && !Number.isFinite(nextState.revision)) {
        nextState = createDefaultChromeInsetState();
    }

    const shouldInheritPositiveAncestorState =
        !incomingState &&
        parseChromeInsetPixelValue(nextState.obscuredTopInset) === 0 &&
        parseChromeInsetPixelValue(nextState.toolbarBottomOffset) === 0 &&
        parseChromeInsetPixelValue(nextState.obscuredBottomInset) === 0 &&
        !!ancestorPositiveState &&
        (
            parseChromeInsetPixelValue(ancestorPositiveState.obscuredTopInset) > 0 ||
            parseChromeInsetPixelValue(ancestorPositiveState.toolbarBottomOffset) > 0 ||
            parseChromeInsetPixelValue(ancestorPositiveState.obscuredBottomInset) > 0
        );

    if (shouldInheritPositiveAncestorState) {
        nextState = {
            ...ancestorPositiveState,
            source: `${ancestorPositiveState.source}->inherited`,
        };
    }

    const incomingWouldZeroPositiveState =
        !!incomingState &&
        parseChromeInsetPixelValue(nextState.obscuredTopInset) === 0 &&
        parseChromeInsetPixelValue(nextState.toolbarBottomOffset) === 0 &&
        parseChromeInsetPixelValue(nextState.obscuredBottomInset) === 0 &&
        (
            parseChromeInsetPixelValue(storedPositiveState.obscuredTopInset) > 0 ||
            parseChromeInsetPixelValue(storedPositiveState.toolbarBottomOffset) > 0 ||
            parseChromeInsetPixelValue(storedPositiveState.obscuredBottomInset) > 0
        );

    if (incomingWouldZeroPositiveState) {
        const shortOverwriteLog = {
            reason,
            message: 'preserved existing non-zero inset over zero candidate',
            attemptedObscuredTopInset: nextState.obscuredTopInset,
            attemptedToolbarBottomOffset: nextState.toolbarBottomOffset,
            attemptedObscuredBottomInset: nextState.obscuredBottomInset,
            lastPositiveObscuredTopInset: storedPositiveState.obscuredTopInset,
            lastPositiveToolbarBottomOffset: storedPositiveState.toolbarBottomOffset,
            lastPositiveObscuredBottomInset: storedPositiveState.obscuredBottomInset,
            attemptedSource: nextState.source,
            attemptedRevision: nextState.revision,
        };
        const overwriteLog = {
            reason,
            attemptedState: nextState,
            previousState,
            storedPositiveState,
        };
        const overwriteKey = JSON.stringify(overwriteLog);
        if (globalThis.__manabiLastChromeInsetsOverwriteLogKey !== overwriteKey) {
            globalThis.__manabiLastChromeInsetsOverwriteLogKey = overwriteKey;
        }
    }

    globalThis.__swiftUIWebViewObscuredInsets = nextState;
    if (
        parseChromeInsetPixelValue(nextState.obscuredTopInset) > 0 ||
        parseChromeInsetPixelValue(nextState.toolbarBottomOffset) > 0 ||
        parseChromeInsetPixelValue(nextState.obscuredBottomInset) > 0
    ) {
        globalThis.__manabiLastPositiveChromeInsets = nextState;
    }
    applyResolvedChromeInsetState(nextState);
    scheduleReaderUIChromeInsetSettle(reason, nextState);
    postReaderUILayoutSnapshot('chromeInsets.applied', {
        reason,
        incomingObscuredTopInset: incomingState?.obscuredTopInset ?? null,
        appliedObscuredTopInset: nextState.obscuredTopInset,
        appliedToolbarBottomOffset: nextState.toolbarBottomOffset,
        appliedObscuredBottomInset: nextState.obscuredBottomInset,
        source: nextState.source,
        revision: nextState.revision,
    });
    const landscapeInsetKey = JSON.stringify({
        appliedObscuredTopInset: nextState.obscuredTopInset,
        appliedToolbarBottomOffset: nextState.toolbarBottomOffset,
        appliedObscuredBottomInset: nextState.obscuredBottomInset,
        source: nextState.source,
        inheritedAncestorSource: shouldInheritPositiveAncestorState ? ancestorPositiveState?.source ?? null : null,
    });
    const shouldLogAppliedInsetChange =
        reason === 'reader.didDisplay' && (
            parseChromeInsetPixelValue(nextState.obscuredTopInset) > 0 ||
            parseChromeInsetPixelValue(nextState.toolbarBottomOffset) > 0 ||
            parseChromeInsetPixelValue(nextState.obscuredBottomInset) > 0 ||
            shouldInheritPositiveAncestorState
        );
    if (shouldLogAppliedInsetChange && globalThis.__manabiLastLandscapeInsetLogKey !== landscapeInsetKey) {
        globalThis.__manabiLastLandscapeInsetLogKey = landscapeInsetKey;
    }
    const chromeInsetsLog = {
        reason,
        locationHref: globalThis.location?.href ?? null,
        topLocationHref: (() => {
            try {
                return window.top?.location?.href ?? null;
            } catch {
                return null;
            }
        })(),
        isTopWindow: (() => {
            try {
                return window.top === window;
            } catch {
                return null;
            }
        })(),
        toolbarBottomOffset: nextState.toolbarBottomOffset,
        obscuredTopInset: nextState.obscuredTopInset,
        obscuredBottomInset: nextState.obscuredBottomInset,
        source: nextState.source,
        revision: nextState.revision,
        inheritedAncestorSource: shouldInheritPositiveAncestorState ? ancestorPositiveState?.source ?? null : null,
        inheritedAncestorObscuredTopInset: shouldInheritPositiveAncestorState ? ancestorPositiveState?.obscuredTopInset ?? null : null,
        inheritedAncestorToolbarBottomOffset: shouldInheritPositiveAncestorState ? ancestorPositiveState?.toolbarBottomOffset ?? null : null,
        inheritedAncestorObscuredBottomInset: shouldInheritPositiveAncestorState ? ancestorPositiveState?.obscuredBottomInset ?? null : null,
        ancestorPositiveObscuredTopInset: ancestorPositiveState?.obscuredTopInset ?? null,
        ancestorPositiveToolbarBottomOffset: ancestorPositiveState?.toolbarBottomOffset ?? null,
        ancestorPositiveObscuredBottomInset: ancestorPositiveState?.obscuredBottomInset ?? null,
        ancestorPositiveSource: ancestorPositiveState?.source ?? null,
        incomingState: incomingState ? normalizeChromeInsetState(incomingState, reason) : null,
        previousState,
        bodyReady: !!document.body,
    };
    const shouldLogChromeInsets = !!globalThis.manabiVerboseLayout;
    const chromeInsetsKey = shouldLogChromeInsets ? JSON.stringify(chromeInsetsLog) : null;
    if (shouldLogChromeInsets && globalThis.__manabiLastChromeInsetsLogKey !== chromeInsetsKey) {
        globalThis.__manabiLastChromeInsetsLogKey = chromeInsetsKey;
    }
    return nextState;
};

window.manabiApplyChromeInsets = (rawState, reason = 'window.manabiApplyChromeInsets') => {
    const nextState = applyStoredChromeInsets(reason, rawState);
    return nextState;
};

document.addEventListener('DOMContentLoaded', () => {
    applyStoredChromeInsets('dom-content-loaded');
});

window.addEventListener('load', () => {
    applyStoredChromeInsets('window-load');
});

const safeRound = (value, digits = 1) =>
    typeof value === 'number' && Number.isFinite(value)
        ? Number(value.toFixed(digits))
        : null;

const getAuthoritativeReaderFraction = ({ navHUD = null, detail = null, fallbackFraction = null } = {}) => {
    return getAuthoritativeReaderFractionDiagnostics({ navHUD, detail, fallbackFraction }).fraction;
};

const getAuthoritativeReaderFractionDiagnostics = ({ navHUD = null, detail = null, fallbackFraction = null } = {}) => {
    const primaryLabelFraction = navHUD?.lastPrimaryLabelDiagnostics?.fraction ?? null;
    if (typeof primaryLabelFraction === 'number' && Number.isFinite(primaryLabelFraction)) {
        return {
            fraction: Math.max(0, Math.min(1, primaryLabelFraction)),
            source: 'primary-label',
            primaryLabelFraction,
            scrubberFraction: null,
            fallbackFraction,
        };
    }
    const scrubberFraction = navHUD?.getScrubberFraction?.(detail ?? null) ?? null;
    if (typeof scrubberFraction === 'number' && Number.isFinite(scrubberFraction)) {
        return {
            fraction: Math.max(0, Math.min(1, scrubberFraction)),
            source: 'scrubber',
            primaryLabelFraction,
            scrubberFraction,
            fallbackFraction,
        };
    }
    if (typeof fallbackFraction === 'number' && Number.isFinite(fallbackFraction)) {
        return {
            fraction: Math.max(0, Math.min(1, fallbackFraction)),
            source: 'fallback',
            primaryLabelFraction,
            scrubberFraction,
            fallbackFraction,
        };
    }
    return {
        fraction: null,
        source: 'none',
        primaryLabelFraction,
        scrubberFraction,
        fallbackFraction,
    };
};

const performanceNowMs = () =>
    typeof performance !== 'undefined' && typeof performance.now === 'function'
        ? performance.now()
        : Date.now();

globalThis.__manabiPerformanceNowMs = performanceNowMs;
globalThis.__manabiSafeRound = safeRound;

const manabiSectionIndexFromLocation = (location) => (
    typeof location?.section?.current === 'number'
        ? location.section.current
        : (typeof location?.sectionIndex === 'number' ? location.sectionIndex : null)
);

const manabiFractionFromLocation = (location) => (
    typeof location?.fraction === 'number' && Number.isFinite(location.fraction)
        ? location.fraction
        : null
);

const manabiCreateInitialRestoreResult = ({
    requestID = null,
    terminalState = 'noTarget',
    requestedLocator = null,
    resolvedLocator = null,
    requestedFraction = null,
    requestedCFI = null,
    location = null,
    navigationOk = null,
    reason = null,
    error = null,
    startedAt = null,
    handledFractionalCompletion = undefined,
    restorePrecision = null,
    restoreDegraded = null,
    fractionTolerance = null,
} = {}) => {
    const currentFraction = manabiFractionFromLocation(location);
    const currentSectionIndex = manabiSectionIndexFromLocation(location);
    const finiteRequestedFraction = Number.isFinite(requestedFraction) ? requestedFraction : null;
    const restoreSatisfied = terminalState === 'satisfied';
    return {
        requestID,
        terminalState,
        requestedLocator,
        resolvedLocator,
        requestedFraction: finiteRequestedFraction,
        currentFraction,
        fractionDelta: finiteRequestedFraction != null && typeof currentFraction === 'number'
            ? Math.abs(currentFraction - finiteRequestedFraction)
            : null,
        handledCFI: restoreSatisfied && typeof requestedCFI === 'string'
            ? requestedCFI
            : null,
        handledFractionalCompletion: restoreSatisfied
            ? (handledFractionalCompletion !== undefined
                ? handledFractionalCompletion
                : (finiteRequestedFraction != null ? finiteRequestedFraction : currentFraction))
            : null,
        currentSectionIndex,
        navigationOk,
        restoreSatisfied,
        restorePrecision,
        restoreDegraded,
        fractionTolerance,
        error,
        reason,
        elapsedMs: startedAt != null ? safeRound(performanceNowMs() - startedAt, 1) : null,
    };
};

const manabiPublishInitialRestoreResult = (result) => {
    globalThis.__manabiInitialRestoreResult = result;
    globalThis.__manabiRestoreDebugLog?.('ebook.initialRestore.terminalResult', {
        ...result,
        requestedFraction: result.requestedFraction != null ? safeRound(result.requestedFraction, 6) : null,
        currentFraction: result.currentFraction != null ? safeRound(result.currentFraction, 6) : null,
        fractionDelta: result.fractionDelta != null ? safeRound(result.fractionDelta, 6) : null,
        handledFractionalCompletion: result.handledFractionalCompletion != null ? safeRound(result.handledFractionalCompletion, 6) : null,
        restorePrecision: result.restorePrecision,
        restoreDegraded: result.restoreDegraded,
        fractionTolerance: result.fractionTolerance != null ? safeRound(result.fractionTolerance, 6) : null,
    });
    return result;
};

const MANABI_TIMELINE_SLOW_THRESHOLD_MS = 1000;
const manabiTimelineValue = value => {
    if (value == null) return 'nil';
    if (typeof value === 'number') return Number.isFinite(value) ? String(safeRound(value, 1)) : String(value);
    if (typeof value === 'boolean') return value ? 'true' : 'false';
    return String(value).replace(/\s+/g, ' ').slice(0, 96);
};
const manabiTimelinePayload = payload => Object.entries(payload || {})
    .filter(([, value]) => value !== undefined)
    .map(([key, value]) => `${key}=${manabiTimelineValue(value)}`)
    .join(' ');
const manabiTimelineShouldEmitMark = (event, payload = {}) => {
    if (globalThis.__manabiTimelineTraceAll === true) return true;
    if (payload?.force === true || payload?.error) return true;
    if (typeof payload?.elapsedMs === 'number') return payload.elapsedMs >= 50;
    const value = String(event || '');
    return value === 'longTask'
        || value.endsWith('.slow')
        || value.endsWith('.error')
        || value.endsWith('.cancel')
        || value.includes('resource.')
        || value.includes('watchdog')
        || value.startsWith('reader.')
        || value.startsWith('viewer.load')
        || value.startsWith('nativeResource.foreground');
};
const manabiTimelineMark = (event, payload = {}) => {
    const details = manabiTimelinePayload(payload);
    const label = details.length > 0 ? `MANABI ${event} ${details}` : `MANABI ${event}`;
    if (!manabiTimelineShouldEmitMark(event, payload)) {
        return label;
    }
    try {
        const eventRecord = {
            event,
            payload,
            label,
            atMs: safeRound(performanceNowMs(), 1),
        };
        const events = globalThis.__manabiTimelineEvents ||= [];
        events.push(eventRecord);
        if (events.length > 200) {
            events.splice(0, events.length - 200);
        }
    } catch (_error) {}
    try {
        performance?.mark?.(label);
    } catch (_error) {}
    return label;
};
const manabiTimelineMeasure = (event, startedAt, payload = {}, thresholdMs = MANABI_TIMELINE_SLOW_THRESHOLD_MS) => {
    const endedAt = performanceNowMs();
    const elapsedMs = endedAt - startedAt;
    if (elapsedMs < thresholdMs && globalThis.__manabiTimelineTraceAll !== true) {
        return elapsedMs;
    }
    const label = manabiTimelineMark(event, { ...payload, elapsedMs });
    try {
        performance?.measure?.(label, { start: startedAt, end: endedAt });
    } catch (_error) {}
    return elapsedMs;
};
globalThis.__manabiTimelineMark = manabiTimelineMark;
globalThis.__manabiTimelineMeasure = manabiTimelineMeasure;
const scheduleNextFrame = (callback) => {
    if (typeof requestAnimationFrame === 'function') {
        return requestAnimationFrame(callback);
    }
    if (typeof setTimeout === 'function') {
        return setTimeout(callback, 0);
    }
    callback();
    return 0;
};
const scheduleAfterNextFrame = (callback) => {
    const postFrameTask = () => {
        if (typeof MessageChannel === 'function') {
            const channel = new MessageChannel();
            channel.port1.onmessage = () => {
                channel.port1.onmessage = null;
                callback();
            };
            channel.port2.postMessage(undefined);
            return channel;
        }
        if (typeof setTimeout === 'function') {
            return setTimeout(callback, 0);
        }
        callback();
        return 0;
    };
    if (typeof requestAnimationFrame === 'function') {
        return requestAnimationFrame(postFrameTask);
    }
    return postFrameTask();
};

const installManabiLongTaskProbe = () => {
    if (globalThis.__manabiLongTaskProbeInstalled === true) return;
    if (typeof PerformanceObserver !== 'function') return;
    globalThis.__manabiLongTaskProbeInstalled = true;
    globalThis.__manabiRecentLongTasks = globalThis.__manabiRecentLongTasks || [];
    try {
        const observer = new PerformanceObserver((list) => {
            for (const entry of list.getEntries?.() ?? []) {
                const longTaskPayload = {
                    durationMs: entry.duration,
                    startMs: entry.startTime,
                    endMs: entry.startTime + entry.duration,
                    name: entry.name || null,
                    frame: 'ebook-viewer',
                    inflightReplaceTextCount: globalThis.__manabiInflightReplaceTextCount ?? 0,
                    foregroundNativeResourcePendingCount: globalThis.__manabiForegroundNativeResourcePendingCount ?? 0,
                    foregroundCriticalSectionCount: globalThis.__manabiForegroundCriticalSectionCount ?? 0,
                };
                globalThis.__manabiRecentLongTasks.push(longTaskPayload);
                if (globalThis.__manabiRecentLongTasks.length > 25) {
                    globalThis.__manabiRecentLongTasks.splice(0, globalThis.__manabiRecentLongTasks.length - 25);
                }
                manabiTimelineMark('longTask', longTaskPayload);
            }
        });
        observer.observe({ type: 'longtask', buffered: true });
        globalThis.__manabiLongTaskObserver = observer;
    } catch (_error) {}
};
installManabiLongTaskProbe();

const installManabiResourceTimingProbe = () => {
    if (globalThis.__manabiResourceTimingProbeInstalled === true) return;
    globalThis.__manabiResourceTimingProbeInstalled = true;
    const slowThresholdMs = 1000;
    const describeRecentLongTaskOverlap = (startMs, endMs) => {
        const tasks = Array.isArray(globalThis.__manabiRecentLongTasks) ? globalThis.__manabiRecentLongTasks : [];
        const overlapping = tasks.filter((task) => {
            const taskStart = Number(task?.startMs);
            const taskEnd = Number(task?.endMs);
            return Number.isFinite(taskStart)
                && Number.isFinite(taskEnd)
                && taskStart <= endMs
                && taskEnd >= startMs;
        });
        if (overlapping.length === 0) {
            return null;
        }
        return {
            count: overlapping.length,
            maxDurationMs: Math.max(...overlapping.map((task) => Number(task.durationMs) || 0)),
            latestStartMs: Math.max(...overlapping.map((task) => Number(task.startMs) || 0)),
        };
    };
    const describeResourceURL = (name, initiatorType = '') => {
        const rawName = typeof name === 'string' ? name : '';
        let blobInfo = null;
        try {
            blobInfo = globalThis.__manabiBlobResourceMap?.get?.(rawName) ?? null;
        } catch (_error) {}
        let decodedName = rawName;
        try {
            decodedName = decodeURIComponent(rawName);
        } catch (_error) {}
        let subpath = null;
        try {
            subpath = new URL(rawName).searchParams.get('subpath');
        } catch (_error) {}
        subpath ??= typeof blobInfo?.href === 'string' ? blobInfo.href : null;
        return {
            name: (blobInfo?.href ?? decodedName).slice(0, 160),
            subpath: subpath ? subpath.slice(0, 120) : null,
            isEbook: rawName.startsWith('ebook://') || rawName.startsWith('blob:ebook://'),
            isCSS: /\.css(?:[?#]|$)/i.test(decodedName)
                || /\.css(?:[?#]|$)/i.test(blobInfo?.href ?? '')
                || blobInfo?.type === 'text/css'
                || rawName.includes('manabi-fonts.css')
                || rawName.includes('text/css')
                || initiatorType === 'link',
        };
    };
    const emitResourceTiming = (entry) => {
        if (!entry || typeof entry.name !== 'string') return;
        const timing = describeResourceURL(entry.name, entry.initiatorType || '');
        if (!timing.isEbook && !timing.isCSS) return;
        const duration = Number.isFinite(entry.duration) ? entry.duration : 0;
        if (duration < slowThresholdMs && globalThis.__manabiTimelineTraceAll !== true) return;
        const startMs = Number.isFinite(entry.startTime) ? entry.startTime : null;
        const responseEndMs = Number.isFinite(entry.responseEnd) ? entry.responseEnd : null;
        manabiTimelineMark(timing.isCSS ? 'resource.css.slow' : 'resource.slow', {
            name: timing.name,
            subpath: timing.subpath,
            initiatorType: entry.initiatorType || null,
            durationMs: duration,
            startMs,
            responseStartMs: Number.isFinite(entry.responseStart) ? entry.responseStart : null,
            responseEndMs,
            transferSize: Number.isFinite(entry.transferSize) ? entry.transferSize : null,
            encodedBodySize: Number.isFinite(entry.encodedBodySize) ? entry.encodedBodySize : null,
            decodedBodySize: Number.isFinite(entry.decodedBodySize) ? entry.decodedBodySize : null,
            foregroundCriticalSectionCount: globalThis.__manabiForegroundCriticalSectionCount ?? 0,
            overlappingLongTask: Number.isFinite(startMs) && Number.isFinite(responseEndMs)
                ? describeRecentLongTaskOverlap(startMs, responseEndMs)
                : null,
        });
    };
    try {
        performance?.getEntriesByType?.('resource')?.forEach?.(emitResourceTiming);
    } catch (_error) {}
    try {
        const observer = new PerformanceObserver((list) => {
            list.getEntries?.().forEach?.(emitResourceTiming);
        });
        observer.observe({ type: 'resource', buffered: true });
        globalThis.__manabiResourceTimingObserver = observer;
    } catch (_error) {}
};
installManabiResourceTimingProbe();

const summarizeRect = (rect) => {
    if (!rect) return null;
    return {
        left: safeRound(rect.left),
        top: safeRound(rect.top),
        right: safeRound(rect.right),
        bottom: safeRound(rect.bottom),
        width: safeRound(rect.width),
        height: safeRound(rect.height),
    };
};

const summarizeElementLayout = (element) => {
    if (!element || element.nodeType !== 1) {
        return null;
    }
    const ownerWindow = element.ownerDocument?.defaultView || window;
    const rect = summarizeRect(element.getBoundingClientRect?.());
    const style = ownerWindow.getComputedStyle?.(element);
    const hiddenAttr = element.hasAttribute?.('hidden') ?? false;
    const ariaHidden = element.getAttribute?.('aria-hidden');
    const text = (element.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 160);
    return {
        hiddenAttr,
        ariaHidden: ariaHidden ?? null,
        display: style?.display ?? null,
        visibility: style?.visibility ?? null,
        opacity: safeRound(Number(style?.opacity)),
        pointerEvents: style?.pointerEvents ?? null,
        overflowX: style?.overflowX ?? null,
        overflowY: style?.overflowY ?? null,
        position: style?.position ?? null,
        top: style?.top ?? null,
        bottom: style?.bottom ?? null,
        left: style?.left ?? null,
        right: style?.right ?? null,
        heightCSS: style?.height ?? null,
        minHeightCSS: style?.minHeight ?? null,
        maxHeightCSS: style?.maxHeight ?? null,
        lineHeight: style?.lineHeight ?? null,
        fontSize: style?.fontSize ?? null,
        paddingTop: style?.paddingTop ?? null,
        paddingBottom: style?.paddingBottom ?? null,
        marginTop: style?.marginTop ?? null,
        marginBottom: style?.marginBottom ?? null,
        contain: style?.contain ?? null,
        boxSizing: style?.boxSizing ?? null,
        text,
        clientWidth: element.clientWidth ?? null,
        clientHeight: element.clientHeight ?? null,
        scrollWidth: element.scrollWidth ?? null,
        scrollHeight: element.scrollHeight ?? null,
        offsetWidth: element instanceof HTMLElement ? element.offsetWidth : null,
        offsetHeight: element instanceof HTMLElement ? element.offsetHeight : null,
        rect,
    };
};

const isDocumentLike = (value) =>
    !!value
    && value.nodeType === 9
    && typeof value.querySelectorAll === 'function'
    && !!value.documentElement;

const visibleRangeForNavigationHUDDocument = (navHUD, doc) => {
    const range = navHUD?.lastRelocateDetail?.range ?? null;
    return range?.commonAncestorContainer?.ownerDocument === doc
        || range?.startContainer?.ownerDocument === doc
        || range?.endContainer?.ownerDocument === doc
        ? range
        : null;
};

const emptySegmentMetadataBootstrap = () => ({
    byID: new Map(),
    idsByEntryID: new Map(),
    hasEntryIDs: false,
    segments: [],
    aggregates: null,
    sentenceArchive: new Map(),
});

const stableSegmentID = (sentenceID, segmentHash) => (
    typeof sentenceID === 'string' && sentenceID.length > 0
    && typeof segmentHash === 'string' && segmentHash.length > 0
        ? `${sentenceID}-${segmentHash}`
        : null
);

const mapLikeOrEmpty = (value) => (
    value && typeof value.get === 'function' && typeof value.keys === 'function'
        ? value
        : new Map()
);

const normalizeSegmentMetadataBootstrap = (bootstrap) => ({
    byID: mapLikeOrEmpty(bootstrap?.byID),
    idsByEntryID: mapLikeOrEmpty(bootstrap?.idsByEntryID),
    hasEntryIDs: bootstrap?.hasEntryIDs === true
        || (bootstrap?.idsByEntryID?.size ?? 0) > 0,
    segmentIDsBySentenceID: mapLikeOrEmpty(bootstrap?.segmentIDsBySentenceID),
    segmentIDsByParagraphID: mapLikeOrEmpty(bootstrap?.segmentIDsByParagraphID),
    segments: Array.isArray(bootstrap?.segments) ? bootstrap.segments : [],
    aggregates: bootstrap?.aggregates || null,
    sentenceArchive: mapLikeOrEmpty(bootstrap?.sentenceArchive),
});

const segmentMetadataBootstrap = (doc) => {
    if (!doc) {
        return emptySegmentMetadataBootstrap();
    }
    if (doc.body?.dataset?.isEbook === 'true' && typeof directSegmentMetadataBootstrap === 'function') {
        try {
            const directMetadata = normalizeSegmentMetadataBootstrap(directSegmentMetadataBootstrap(doc));
            if (directMetadata.byID.size > 0) {
                return directMetadata;
            }
        } catch (_error) {}
    }
    const readerBootstrap = doc.defaultView?.manabi_bootstrapSegmentMetadata;
    if (typeof readerBootstrap === 'function') {
        try {
            const readerMetadata = normalizeSegmentMetadataBootstrap(readerBootstrap(doc));
            if (readerMetadata.byID.size > 0) {
                return readerMetadata;
            }
        } catch (_error) {}
    }
    if (typeof directSegmentMetadataBootstrap !== 'function') {
        return emptySegmentMetadataBootstrap();
    }
    try {
        return normalizeSegmentMetadataBootstrap(directSegmentMetadataBootstrap(doc));
    } catch (_error) {
        return emptySegmentMetadataBootstrap();
    }
};

const segmentMetadataForNode = (segmentNode, bootstrap = null) => {
    if (!segmentNode) return null;
    const doc = segmentNode.ownerDocument || document;
    const resolvedBootstrap = bootstrap || segmentMetadataBootstrap(doc);
    const byID = resolvedBootstrap.byID;
    if (!byID || typeof byID.get !== 'function' || byID.size === 0) {
        return null;
    }
    const aliases = [];
    const addAlias = (identifier) => {
        if (typeof identifier !== 'string' || identifier.length === 0) return;
        if (!aliases.includes(identifier)) aliases.push(identifier);
    };
    addAlias(segmentNode.id);
    addAlias(segmentNode.getAttribute?.('id'));
    for (const alias of aliases) {
        const metadata = byID.get(alias);
        if (metadata) {
            return metadata;
        }
    }
    return null;
};

const segmentEntryIDsForNode = (segmentNode, kind = 'primary', bootstrap = null, metadata = null) => {
    const resolvedMetadata = metadata || segmentMetadataForNode(segmentNode, bootstrap);
    const jmdictEntryIds = Array.isArray(resolvedMetadata?.j) ? resolvedMetadata.j : [];
    const jmnedictEntryIds = Array.isArray(resolvedMetadata?.n) ? resolvedMetadata.n : [];
    if (kind === 'jmdict') return jmdictEntryIds;
    if (kind === 'jmnedict') return jmnedictEntryIds;
    return jmdictEntryIds.length ? jmdictEntryIds : jmnedictEntryIds;
};

const segmentEntryIDsForMetadata = (metadata, kind = 'primary') => {
    const jmdictEntryIds = Array.isArray(metadata?.j) ? metadata.j : [];
    const jmnedictEntryIds = Array.isArray(metadata?.n) ? metadata.n : [];
    if (kind === 'jmdict') return jmdictEntryIds;
    if (kind === 'jmnedict') return jmnedictEntryIds;
    return jmdictEntryIds.length ? jmdictEntryIds : jmnedictEntryIds;
};

const prepareVisibleSegmentItem = (item, bootstrap = null) => {
    const node = item?.node ?? null;
    if (!node) return item;
    const metadata = item.segmentMetadata || segmentMetadataForNode(node, bootstrap) || {};
    const jmdictEntryIDs = segmentEntryIDsForMetadata(metadata, 'jmdict');
    const jmnedictEntryIDs = segmentEntryIDsForMetadata(metadata, 'jmnedict');
    const primaryEntryIDs = jmdictEntryIDs.length ? jmdictEntryIDs : jmnedictEntryIDs;
    item.segmentMetadata = metadata;
    item.jmdictEntryIDs = jmdictEntryIDs;
    item.jmnedictEntryIDs = jmnedictEntryIDs;
    item.primaryEntryIDs = primaryEntryIDs;
    item.lookupIdentity = {
        jmdictEntryIDs,
        jmnedictEntryIDs,
        primaryEntryIDs,
        jmdictSearchString: typeof metadata.s === 'string' ? metadata.s : null,
        jmnedictSearchString: typeof metadata.ns === 'string' ? metadata.ns : null,
    };
    return item;
};

const prepareVisibleSegmentsResult = (visibleSegmentsResult, doc = null) => {
    if (visibleSegmentsResult?.preparedVisiblePayload === true && visibleSegmentsResult?.segmentMetadataBootstrap) {
        return visibleSegmentsResult;
    }
    const visibleSegments = visibleSegmentsResult?.visibleSegments;
    if (!Array.isArray(visibleSegments) || visibleSegments.length === 0) {
        return visibleSegmentsResult;
    }
    const bootstrap = visibleSegmentsResult?.segmentMetadataBootstrap || segmentMetadataBootstrap(doc || visibleSegments[0]?.node?.ownerDocument);
    for (const item of visibleSegments) {
        prepareVisibleSegmentItem(item, bootstrap);
    }
    visibleSegmentsResult.segmentMetadataBootstrap = bootstrap;
    visibleSegmentsResult.preparedVisiblePayload = true;
    return visibleSegmentsResult;
};

const visibleSegmentPreparedEntrySignature = (visibleSegments = []) => (
    visibleSegments
        .map((item) => `${item?.node?.id || item?.segmentIdentifier || ''}:${(item?.primaryEntryIDs || []).join(',')}`)
        .join(';')
);

const normalizeArticleReadingProgress = (articleReadingProgress = {}) => ({
    sentenceIdentifiersRead: Array.isArray(articleReadingProgress?.sentenceIdentifiersRead)
        ? articleReadingProgress.sentenceIdentifiersRead
        : [],
    readSegmentIdentifiers: Array.isArray(articleReadingProgress?.readSegmentIdentifiers)
        ? articleReadingProgress.readSegmentIdentifiers
        : [],
    articleSentenceCount: Number.isFinite(articleReadingProgress?.articleSentenceCount)
        ? articleReadingProgress.articleSentenceCount
        : null,
    articleMarkedAsFinished: !!articleReadingProgress?.articleMarkedAsFinished,
});

const sentenceIdentifierForNode = (sentenceNode) => {
    const sentenceIdentifier = sentenceNode?.getAttribute?.('sid');
    return typeof sentenceIdentifier === 'string' && sentenceIdentifier.length > 0
        ? sentenceIdentifier
        : null;
};

// Reader segment identity contract mirrors manabi_reader.js: the DOM id is compact
// and runtime-scoped, while sidecar sid is the durable content identity.
const segmentIdentityForNode = (segmentNode, bootstrap = null, metadata = null) => {
    metadata = metadata || segmentMetadataForNode(segmentNode, bootstrap);
    return ebookSegmentIdentity(segmentNode, metadata);
};

const segmentIdentifierForNode = (segmentNode, bootstrap = null, metadata = null) => {
    return segmentIdentityForNode(segmentNode, bootstrap, metadata).segmentIdentifier;
};

const segmentIdentifierAliasesForNode = (segmentNode, bootstrap = null, metadata = null) => {
    metadata = metadata || segmentMetadataForNode(segmentNode, bootstrap);
    return ebookSegmentIdentifierAliases(segmentNode, metadata);
};

const buildExampleSentenceForSegment = (segmentNode, bootstrap = null, metadata = null) => {
    const doc = segmentNode?.ownerDocument || document;
    const resolvedBootstrap = bootstrap || segmentMetadataBootstrap(doc);
    metadata = metadata || segmentMetadataForNode(segmentNode, resolvedBootstrap);
    const sentenceID = metadata?.sentenceID || sentenceIdentifierForNode(segmentNode?.closest?.(manabiReaderSentenceSelector)) || null;
    const sidecarSentence = sentenceID
        ? resolvedBootstrap.sentenceArchive?.get?.(sentenceID)
        : null;
    if (sidecarSentence) {
        return {
            sentenceHTML: sidecarSentence.sentenceHTML ?? null,
            sentenceJMDictIDs: sidecarSentence.sentenceJMDictIDs ?? null,
        };
    }
    const sentenceNode = segmentNode?.closest?.(manabiReaderSentenceSelector);
    if (!(sentenceNode instanceof Element)) {
        return {
            sentenceHTML: null,
            sentenceJMDictIDs: null,
        };
    }
    const sentenceJMDictIDs = new Set();
    for (const nestedSegment of sentenceNode.querySelectorAll(manabiReaderSegmentSelector)) {
        for (const entryID of segmentEntryIDsForNode(nestedSegment, 'jmdict', resolvedBootstrap)) {
            sentenceJMDictIDs.add(entryID);
        }
    }
    return {
        sentenceHTML: sentenceNode.outerHTML,
        sentenceJMDictIDs: sentenceJMDictIDs.size > 0 ? Array.from(sentenceJMDictIDs) : null,
    };
};

const rectHasPositiveFiniteSize = (rect) => {
    return Number.isFinite(rect?.left)
        && Number.isFinite(rect?.top)
        && Number.isFinite(rect?.right)
        && Number.isFinite(rect?.bottom)
        && Number.isFinite(rect?.width)
        && Number.isFinite(rect?.height)
        && rect.width > 0
        && rect.height > 0;
};

const rectIntersectsViewport = (rect, viewportWidth, viewportHeight) => {
    if (!rectHasPositiveFiniteSize(rect)
        || !Number.isFinite(viewportWidth)
        || !Number.isFinite(viewportHeight)) {
        return false;
    }
    return rect.right > 0
        && rect.bottom > 0
        && rect.left < viewportWidth
        && rect.top < viewportHeight;
};

const rectIntersectsBounds = (rect, bounds) => {
    if (!rectHasPositiveFiniteSize(rect)
        || !Number.isFinite(bounds?.left)
        || !Number.isFinite(bounds?.top)
        || !Number.isFinite(bounds?.right)
        || !Number.isFinite(bounds?.bottom)) {
        return false;
    }
    return rect.right > bounds.left
        && rect.bottom > bounds.top
        && rect.left < bounds.right
        && rect.top < bounds.bottom;
};

const positiveBoundingClientRectForNode = (node) => {
    if (typeof node?.getBoundingClientRect !== 'function') {
        return null;
    }
    const rect = node.getBoundingClientRect();
    return rect && rect.width > 0 && rect.height > 0 ? rect : null;
};

const positiveClientRectsForNode = (node, {
    includeBoundingFallback = true,
} = {}) => {
    if (typeof node?.getClientRects === 'function') {
        const rects = Array.from(node.getClientRects()).filter((rect) => rect && rect.width > 0 && rect.height > 0);
        if (rects.length > 0) {
            return rects;
        }
    }
    if (!includeBoundingFallback) {
        return [];
    }
    const boundingRect = positiveBoundingClientRectForNode(node);
    return boundingRect ? [boundingRect] : [];
};

const visibleClientRectsForNode = (node, bounds, measuredBoundingRect = null) => {
    const clientRects = positiveClientRectsForNode(node, { includeBoundingFallback: false });
    const visibleRects = clientRects.filter((rect) => rectIntersectsBounds(rect, bounds));
    if (visibleRects.length > 0) {
        return visibleRects;
    }
    const boundingRect = measuredBoundingRect || positiveBoundingClientRectForNode(node);
    return rectIntersectsBounds(boundingRect, bounds) ? [boundingRect] : [];
};

const measuredVisibleRectsForSegmentNode = (segmentNode, visibleBounds, {
    assumeInVisibleRange = false,
    includeClientRects = true,
    measuredBoundingRect = null,
} = {}) => {
    if (includeClientRects) {
        const rects = assumeInVisibleRange
            ? positiveClientRectsForNode(segmentNode)
            : visibleClientRectsForNode(segmentNode, visibleBounds, measuredBoundingRect);
        return {
            rect: rects[0] ?? null,
            rects,
        };
    }
    const boundingRect = measuredBoundingRect || positiveBoundingClientRectForNode(segmentNode);
    const rect = (assumeInVisibleRange && !!boundingRect)
        || rectIntersectsBounds(boundingRect, visibleBounds)
        ? boundingRect
        : null;
    return {
        rect,
        rects: [],
    };
};

const viewportBoundsForReaderDocument = (doc) => {
    const frameElement = doc?.defaultView?.frameElement ?? null;
    if (frameElement instanceof HTMLIFrameElement) {
        const viewElement = frameElement.parentElement;
        const paginatorContainer = viewElement?.parentElement ?? null;
        const hasExpectedPaginatorContainer = paginatorContainer?.id === 'container';
        const containerRect = hasExpectedPaginatorContainer
            ? paginatorContainer.getBoundingClientRect()
            : null;
        const frameRect = frameElement.getBoundingClientRect();
        const hasGeometry = containerRect
            && frameRect
            && Number.isFinite(containerRect.width)
            && Number.isFinite(containerRect.height)
            && Number.isFinite(frameRect.left)
            && Number.isFinite(frameRect.top)
            && containerRect.width > 0
            && containerRect.height > 0;
        if (!hasGeometry) {
            return {
                viewportWidth: 0,
                viewportHeight: 0,
                viewportLeft: 0,
                viewportTop: 0,
                visibleBounds: null,
                frameRect,
                containerRect,
                hasExpectedPaginatorContainer,
            };
        }
        return {
            viewportWidth: containerRect.width,
            viewportHeight: containerRect.height,
            viewportLeft: containerRect.left,
            viewportTop: containerRect.top,
            visibleBounds: {
                left: containerRect.left - frameRect.left,
                top: containerRect.top - frameRect.top,
                right: containerRect.right - frameRect.left,
                bottom: containerRect.bottom - frameRect.top,
            },
            frameRect,
            containerRect,
            hasExpectedPaginatorContainer,
        };
    }
    const viewportWidth = doc?.documentElement?.clientWidth || doc?.defaultView?.innerWidth || 0;
    const viewportHeight = doc?.documentElement?.clientHeight || doc?.defaultView?.innerHeight || 0;
    return {
        viewportWidth,
        viewportHeight,
        viewportLeft: 0,
        viewportTop: 0,
        visibleBounds: {
            left: 0,
            top: 0,
            right: viewportWidth,
            bottom: viewportHeight,
        },
        frameRect: null,
        containerRect: null,
        hasExpectedPaginatorContainer: null,
    };
};

const segmentOrderCacheByDocument = new WeakMap();

const isEbookContentDocument = (doc) => {
    const href = doc?.location?.href || doc?.URL || '';
    return doc?.defaultView?.manabi_isEbook === true
        || doc?.body?.dataset?.isEbook === 'true'
        || typeof doc?.body?.dataset?.mnbSourceHref === 'string'
        || href.startsWith('blob:ebook://')
        || href.startsWith('ebook://');
};

const orderedSegmentNodesForDocument = (doc) => {
    const cached = segmentOrderCacheByDocument.get(doc);
    if (cached?.root === doc.body) {
        return cached;
    }
    const nodes = Array.from(doc.querySelectorAll?.('m-m') ?? []);
    const indexByNode = new Map();
    nodes.forEach((node, index) => {
        indexByNode.set(node, index);
    });
    const entry = {
        root: doc.body,
        nodes,
        indexByNode,
    };
    segmentOrderCacheByDocument.set(doc, entry);
    return entry;
};

const compareSegmentNodesInDocumentOrder = (first, second, indexByNode = null) => {
    if (!first || !second || first === second) return 0;
    const firstIndex = indexByNode?.get?.(first);
    const secondIndex = indexByNode?.get?.(second);
    if (Number.isFinite(firstIndex) && Number.isFinite(secondIndex)) {
        return firstIndex - secondIndex;
    }
    const position = first.compareDocumentPosition?.(second) ?? 0;
    if (position & Node.DOCUMENT_POSITION_PRECEDING) return 1;
    if (position & Node.DOCUMENT_POSITION_FOLLOWING) return -1;
    return 0;
};

const pageTurnSentinelSegmentSeedNodes = (doc, visibleSentinelIDs = null, margin = 8) => {
    if (!isDocumentLike(doc) || !Array.isArray(visibleSentinelIDs) || visibleSentinelIDs.length === 0) {
        return [];
    }
    const orderedSegments = orderedSegmentNodesForDocument(doc);
    const nodes = orderedSegments.nodes;
    if (!Array.isArray(nodes) || nodes.length === 0) {
        return [];
    }
    const sentinels = visibleSentinelIDs
        .map((id) => typeof id === 'string' && id.length > 0 ? doc.getElementById(id) : null)
        .filter((element) => element?.isConnected !== false);
    if (sentinels.length === 0) {
        return [];
    }
    const boundaryIndexes = [];
    for (const sentinel of sentinels) {
        let lastPrecedingIndex = null;
        let firstFollowingIndex = null;
        for (let index = 0; index < nodes.length; index += 1) {
            const segment = nodes[index];
            if (!segment) continue;
            if (segment.contains?.(sentinel)) {
                boundaryIndexes.push(index);
                lastPrecedingIndex = index;
                firstFollowingIndex = index;
                break;
            }
            const position = sentinel.compareDocumentPosition?.(segment) ?? 0;
            if (position & Node.DOCUMENT_POSITION_PRECEDING) {
                lastPrecedingIndex = index;
                continue;
            }
            if (position & Node.DOCUMENT_POSITION_FOLLOWING) {
                firstFollowingIndex = index;
                break;
            }
        }
        if (Number.isFinite(lastPrecedingIndex)) {
            boundaryIndexes.push(lastPrecedingIndex);
        }
        if (Number.isFinite(firstFollowingIndex)) {
            boundaryIndexes.push(firstFollowingIndex);
        }
    }
    if (boundaryIndexes.length === 0) {
        return [];
    }
    const normalizedMargin = Number.isFinite(margin) && margin > 0 ? Math.floor(margin) : 0;
    const start = Math.max(0, Math.min(...boundaryIndexes) - normalizedMargin);
    const end = Math.min(nodes.length - 1, Math.max(...boundaryIndexes) + normalizedMargin);
    const seedNodes = [];
    for (let index = start; index <= end; index += 1) {
        const node = nodes[index];
        if (node?.isConnected !== false) {
            seedNodes.push(node);
        }
    }
    return seedNodes;
};

const rangeBoundarySegmentIndex = (visibleRange, boundary, orderedSegments) => {
    const startElement = visibleRange.startContainer?.nodeType === Node.ELEMENT_NODE
        ? visibleRange.startContainer
        : visibleRange.startContainer?.parentElement;
    const endElement = visibleRange.endContainer?.nodeType === Node.ELEMENT_NODE
        ? visibleRange.endContainer
        : visibleRange.endContainer?.parentElement;
    const element = boundary === 'end' ? endElement : startElement;
    const directSegment = element?.closest?.(manabiReaderSegmentSelector);
    if (directSegment && orderedSegments.indexByNode.has(directSegment)) {
        return orderedSegments.indexByNode.get(directSegment);
    }
    const sentence = element?.closest?.(manabiReaderSentenceSelector);
    if (sentence?.nodeType === Node.ELEMENT_NODE) {
        const sentenceSegments = Array.from(sentence.querySelectorAll?.('m-m') ?? []);
        const segment = boundary === 'end'
            ? sentenceSegments[sentenceSegments.length - 1]
            : sentenceSegments[0];
        if (segment && orderedSegments.indexByNode.has(segment)) {
            return orderedSegments.indexByNode.get(segment);
        }
    }
    return null;
};

const collectSegmentNodesInVisibleRange = (visibleRange) => {
    const doc = visibleRange?.commonAncestorContainer?.ownerDocument
        || visibleRange?.startContainer?.ownerDocument
        || visibleRange?.endContainer?.ownerDocument
        || null;
    if (!doc || !visibleRange?.commonAncestorContainer) {
        return null;
    }
    const root = visibleRange.commonAncestorContainer?.nodeType === Node.ELEMENT_NODE
        ? visibleRange.commonAncestorContainer
        : visibleRange.commonAncestorContainer?.parentElement;
    if (!root) {
        return null;
    }
    const nodes = [];
    const appendSegment = (node) => {
        if (node?.nodeType !== Node.ELEMENT_NODE) return;
        if (node.matches?.(manabiReaderSegmentSelector)) {
            nodes.push(node);
        }
    };
    appendSegment(root);
    const walker = doc.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, {
        acceptNode(node) {
            if (node === root) return NodeFilter.FILTER_SKIP;
            try {
                return visibleRange.intersectsNode(node)
                    ? NodeFilter.FILTER_ACCEPT
                    : NodeFilter.FILTER_REJECT;
            } catch (_error) {
                return NodeFilter.FILTER_REJECT;
            }
        },
    });
    let current = walker.nextNode();
    while (current) {
        appendSegment(current);
        current = walker.nextNode();
    }
    return nodes.length > 0 ? nodes : null;
};

const isBroadEbookRangeRoot = (root, doc) => {
    if (!root || !isEbookContentDocument(doc)) {
        return false;
    }
    if (root === doc || root === doc.body || root === doc.documentElement) {
        return true;
    }
    const tagName = root?.tagName?.toLowerCase?.() ?? '';
    return tagName === 'body' || tagName === 'html';
};

let visibleSegmentCollectionNodeID = 1;
const visibleSegmentCollectionNodeIDs = new WeakMap();
const visibleSegmentCollectionNodeKey = (node) => {
    if (!node || (typeof node !== 'object' && typeof node !== 'function')) {
        return 'nil';
    }
    let key = visibleSegmentCollectionNodeIDs.get(node);
    if (!key) {
        key = visibleSegmentCollectionNodeID++;
        visibleSegmentCollectionNodeIDs.set(node, key);
    }
    return key;
};
const visibleRangeCollectionSignature = (visibleRange) => {
    if (!visibleRange || visibleRange.collapsed === true) {
        return visibleRange?.collapsed === true ? 'collapsed' : 'none';
    }
    return [
        visibleSegmentCollectionNodeKey(visibleRange.startContainer),
        visibleRange.startOffset ?? 0,
        visibleSegmentCollectionNodeKey(visibleRange.endContainer),
        visibleRange.endOffset ?? 0,
        visibleSegmentCollectionNodeKey(visibleRange.commonAncestorContainer),
    ].join(':');
};
const visibleBoundsCollectionSignature = (visibleBounds) => {
    if (!visibleBounds) return 'none';
    return [
        visibleBounds.left,
        visibleBounds.top,
        visibleBounds.right,
        visibleBounds.bottom,
        visibleBounds.width,
        visibleBounds.height,
    ].map((value) => Number.isFinite(value) ? Math.round(value) : 'nil').join(':');
};
const visibleSegmentCollectionCacheKey = (doc, visibleRange, visibleBounds, {
    includeClientRects = true,
    includeSegmentMetadata = true,
    viewportSampleDensity = null,
    minimumViewportSampleSegmentCount = 0,
    seedSegmentSignature = null,
    useOrderedDocumentWindow = false,
} = {}) => {
    const view = doc?.defaultView ?? null;
    return [
        view?.__manabiVisibleSegmentCollectionGeneration ?? 0,
        view?.__manabiReaderRenderToken ?? '',
        includeClientRects ? 'rects' : 'bounds',
        includeSegmentMetadata ? 'metadata' : 'runtime-identity',
        viewportSampleDensity || 'auto',
        minimumViewportSampleSegmentCount,
        seedSegmentSignature || 'no-seed',
        useOrderedDocumentWindow ? 'ordered-document-window' : 'no-ordered-document-window',
        visibleRangeCollectionSignature(visibleRange),
        visibleBoundsCollectionSignature(visibleBounds),
    ].join('|');
};
const shouldInvalidateVisibleSegmentGeometryForReason = (sourceReason = 'unspecified') => {
    const reason = String(sourceReason || 'unspecified');
    return reason === 'page-turn-start'
        || reason === 'lookup-navigation-page-turn-start'
        || reason === 'page-turn-swipe-intent'
        || reason === 'document-load'
        || reason === 'font-family-change'
        || reason === 'font-family-change-child'
        || reason === 'font-size-change'
        || reason === 'font-size-change-child'
        || reason === 'layout-change'
        || reason === 'writing-direction-change'
        || reason.includes('resize')
        || reason.includes('orientation')
        || reason.includes('renderer.goTo')
        || reason.includes('renderer.relocate')
        || reason.includes('navigation');
};
const cachedVisibleSegmentCollection = (doc, key) => {
    if (!key || !doc?.__manabiVisibleSegmentCollectionCache) return null;
    const cache = doc.__manabiVisibleSegmentCollectionCache;
    return cache.key === key ? cache.result : null;
};
const cacheVisibleSegmentCollection = (doc, key, result) => {
    if (!key || !isDocumentLike(doc)) return;
    doc.__manabiVisibleSegmentCollectionCache = { key, result };
};
const collectViewportSampleSegmentNodes = (doc, visibleBounds, {
    sampleDensity = 'normal',
} = {}) => {
    if (!isDocumentLike(doc) || !visibleBounds) {
        return null;
    }
    const startedAt = performanceNowMs();
    const isEbookDoc = isEbookContentDocument(doc);
    if (isEbookDoc) {
        if (typeof doc.elementFromPoint !== 'function') {
            return null;
        }
    } else if (typeof doc.elementsFromPoint !== 'function') {
        return null;
    }
    const useMinimalSampling = sampleDensity === 'minimal';
    const useSparseSampling = sampleDensity === 'sparse' || useMinimalSampling;
    const useStatusSampling = sampleDensity === 'status';
    const xFractions = useMinimalSampling
        ? [0.25, 0.5, 0.75]
        : useSparseSampling
        ? [0.5]
        : (useStatusSampling && isEbookDoc
            ? [0.18, 0.38, 0.62, 0.82]
            : (isEbookDoc ? [0.12, 0.25, 0.38, 0.5, 0.62, 0.75, 0.88] : [0.08, 0.18, 0.28, 0.38, 0.5, 0.62, 0.72, 0.82, 0.92]));
    const yFractions = useSparseSampling
        ? [0.2, 0.5, 0.8]
        : (useStatusSampling && isEbookDoc
            ? [0.18, 0.5, 0.82]
            : (isEbookDoc ? [0.12, 0.28, 0.44, 0.6, 0.76, 0.92] : [0.1, 0.22, 0.34, 0.46, 0.58, 0.7, 0.82, 0.94]));
    const candidateSegments = [];
    const candidateLimit = useMinimalSampling ? 8 : (useSparseSampling ? 96 : (isEbookDoc ? 96 : 512));
    const seenSegments = new Set();
    const seenRoots = new Set();
    const left = Math.max(0, Math.floor(visibleBounds.left || 0));
    const top = Math.max(0, Math.floor(visibleBounds.top || 0));
    const right = Math.max(left, Math.ceil(visibleBounds.right || 0));
    const bottom = Math.max(top, Math.ceil(visibleBounds.bottom || 0));
    const width = right - left;
    const height = bottom - top;
    if (width <= 0 || height <= 0) {
        return null;
    }
    const appendSegment = (segment, { allowOverLimit = false } = {}) => {
        if (!allowOverLimit && candidateSegments.length >= candidateLimit) {
            return;
        }
        if (segment?.tagName?.toLowerCase?.() !== 'm-m' || seenSegments.has(segment)) {
            return;
        }
        seenSegments.add(segment);
        candidateSegments.push(segment);
    };
    const appendRootSegments = (root) => {
        if (!(root instanceof Element) || root === doc.body || root === doc.documentElement || seenRoots.has(root)) {
            return;
        }
        seenRoots.add(root);
        if (root.matches?.(manabiReaderSegmentSelector)) {
            appendSegment(root);
            return;
        }
        if (!root.matches?.('m-s, p, li, h1, h2, h3, h4, h5, h6, blockquote, figure')) {
            return;
        }
        for (const segment of root.querySelectorAll?.('m-m') ?? []) {
            appendSegment(segment);
            if (candidateSegments.length >= candidateLimit) {
                break;
            }
        }
    };
    const appendCaretSegment = (x, y) => {
        let node = null;
        try {
            node = doc.caretPositionFromPoint?.(x, y)?.offsetNode ?? null;
        } catch (_error) {}
        if (!node) {
            try {
                node = doc.caretRangeFromPoint?.(x, y)?.startContainer ?? null;
            } catch (_error) {}
        }
        const element = node?.nodeType === Node.ELEMENT_NODE
            ? node
            : node?.parentElement;
        appendSegment(element);
        appendSegment(element?.closest?.(manabiReaderSegmentSelector));
        appendRootSegments(element?.closest?.('m-s, p, li, h1, h2, h3, h4, h5, h6, blockquote, figure'));
    };
    let sampledPointCount = 0;
    let caretSampleCount = 0;
    for (const yFraction of yFractions) {
        const y = Math.min(bottom - 1, Math.max(top, Math.round(top + height * yFraction)));
        for (const xFraction of xFractions) {
            const x = Math.min(right - 1, Math.max(left, Math.round(left + width * xFraction)));
            sampledPointCount += 1;
            if (!isEbookDoc) {
                appendCaretSegment(x, y);
                caretSampleCount += 1;
            }
            const sampledElements = isEbookDoc
                ? [doc.elementFromPoint?.(x, y)].filter(Boolean)
                : (doc.elementsFromPoint(x, y) || []);
            for (const element of sampledElements) {
                appendSegment(element);
                appendSegment(element?.closest?.(manabiReaderSegmentSelector));
                if (!isEbookDoc) {
                    appendRootSegments(element?.closest?.('m-s, p, li, h1, h2, h3, h4, h5, h6, blockquote, figure'));
                }
                if (candidateSegments.length >= candidateLimit) {
                    break;
                }
            }
        }
    }
    let sampledSegmentIndexByNode = null;
    if (isEbookDoc && candidateSegments.length > 0 && !useMinimalSampling) {
        const orderedSegments = orderedSegmentNodesForDocument(doc);
        const allSegments = orderedSegments.nodes;
        const indexByNode = orderedSegments.indexByNode;
        sampledSegmentIndexByNode = indexByNode;
        const candidateExpansionLimit = candidateLimit + 48;
        const appendNearbySegment = (segment) => {
            if (candidateSegments.length >= candidateExpansionLimit) {
                return;
            }
            appendSegment(segment, { allowOverLimit: true });
        };
        const sampledIndexes = candidateSegments
            .map((segment) => indexByNode.get(segment))
            .filter((index) => Number.isFinite(index));
        if (sampledIndexes.length > 0) {
            const firstSampledIndex = Math.min(...sampledIndexes);
            const lastSampledIndex = Math.max(...sampledIndexes);
            const orderedWindowMargin = useStatusSampling ? 8 : 4;
            const windowStart = Math.max(0, firstSampledIndex - orderedWindowMargin);
            const windowEnd = Math.min(allSegments.length - 1, lastSampledIndex + orderedWindowMargin);
            for (let index = windowStart; index <= windowEnd; index += 1) {
                appendNearbySegment(allSegments[index] ?? null);
            }
        } else {
            for (const segment of [...candidateSegments]) {
                const index = indexByNode.get(segment);
                if (!Number.isFinite(index)) {
                    continue;
                }
                for (let offset = -2; offset <= 2; offset += 1) {
                    if (offset === 0) {
                        continue;
                    }
                    appendNearbySegment(allSegments[index + offset] ?? null);
                }
            }
        }
    }
    if (isEbookDoc && candidateSegments.length === 0 && !useMinimalSampling) {
        const orderedSegments = orderedSegmentNodesForDocument(doc);
        for (const segment of orderedSegments.nodes.slice(0, candidateLimit)) {
            appendSegment(segment);
        }
    }
    candidateSegments.sort((first, second) => compareSegmentNodesInDocumentOrder(first, second, sampledSegmentIndexByNode));
    manabiTimelineMeasure('visibleSegments.viewportSample', startedAt, {
        sampleDensity,
        sampledPointCount,
        caretSampleCount,
        rootCount: seenRoots.size,
        candidateCount: candidateSegments.length,
        nearbyExpansionEnabled: isEbookDoc,
    }, 20);
    return candidateSegments.length > 0 ? candidateSegments : null;
};

const measureVisibleSegmentsInWindow = (segmentNodes, visibleRange, visibleBounds, {
    assumeInVisibleRange = false,
    includeClientRects = true,
    bootstrap = null,
} = {}) => {
    const visibleSegments = [];
    let hiddenTooltipCount = 0;
    let missingIdentifierCount = 0;
    let outOfViewportCount = 0;
    let visibleRangeCheckCount = 0;
    let visibleRangeErrorCount = 0;
    let rectMeasureCount = 0;
    let rectMeasureElapsedMs = 0;
    let rangeCheckElapsedMs = 0;
    for (const segmentNode of segmentNodes) {
        if (segmentNode.closest('.tippy-box')) {
            hiddenTooltipCount += 1;
            continue;
        }
        const segmentMetadata = segmentMetadataForNode(segmentNode, bootstrap);
        const segmentIdentifier = segmentIdentifierForNode(segmentNode, bootstrap, segmentMetadata);
        if (!segmentIdentifier) {
            missingIdentifierCount += 1;
            continue;
        }
        let isInVisibleRange = true;
        if (!assumeInVisibleRange) {
            const rangeStartedAt = performance.now();
            isInVisibleRange = false;
            try {
                visibleRangeCheckCount += 1;
                isInVisibleRange = visibleRange.intersectsNode(segmentNode);
                rangeCheckElapsedMs += performance.now() - rangeStartedAt;
            } catch (_error) {
                visibleRangeErrorCount += 1;
                rangeCheckElapsedMs += performance.now() - rangeStartedAt;
            }
        }
        if (!isInVisibleRange) {
            outOfViewportCount += 1;
            continue;
        }
        const rectStartedAt = performance.now();
        let measuredBoundingRect = null;
        if (!assumeInVisibleRange && !!visibleBounds) {
            measuredBoundingRect = positiveBoundingClientRectForNode(segmentNode);
            rectMeasureCount += 1;
            if (!rectIntersectsBounds(measuredBoundingRect, visibleBounds)) {
                rectMeasureElapsedMs += performance.now() - rectStartedAt;
                outOfViewportCount += 1;
                continue;
            }
        }
        const { rect, rects } = measuredVisibleRectsForSegmentNode(segmentNode, visibleBounds, {
            assumeInVisibleRange,
            includeClientRects,
            measuredBoundingRect,
        });
        if (!measuredBoundingRect) {
            rectMeasureCount += 1;
        }
        rectMeasureElapsedMs += performance.now() - rectStartedAt;
        if (!rect) {
            outOfViewportCount += 1;
            continue;
        }
        const sentenceNode = segmentNode.closest(manabiReaderSentenceSelector);
        visibleSegments.push({
            node: segmentNode,
            rect,
            rects,
            segmentIdentifier,
            segmentIdentifierAliases: segmentIdentifierAliasesForNode(segmentNode, bootstrap, segmentMetadata),
            sentenceIdentifier: sentenceIdentifierForNode(sentenceNode),
            segmentMetadata,
        });
    }
    return {
        visibleSegments,
        hiddenTooltipCount,
        missingIdentifierCount,
        outOfViewportCount,
        visibleRangeCheckCount,
        visibleRangeErrorCount,
        rectMeasureCount,
        rectMeasureElapsedMs,
        rangeCheckElapsedMs,
    };
};

const mergeMeasuredVisibleSegments = (baseSegments, measuredSegments) => {
    const mergedSegments = Array.isArray(baseSegments) ? [...baseSegments] : [];
    const seenNodes = new Set(mergedSegments.map(item => item?.node).filter(Boolean));
    let mergedCount = 0;
    for (const item of measuredSegments ?? []) {
        if (!item?.node || seenNodes.has(item.node)) {
            continue;
        }
        seenNodes.add(item.node);
        mergedSegments.push(item);
        mergedCount += 1;
    }
    mergedSegments.sort((first, second) => {
        const firstNode = first?.node ?? null;
        const secondNode = second?.node ?? null;
        if (!firstNode || !secondNode || firstNode === secondNode) return 0;
        const position = firstNode.compareDocumentPosition?.(secondNode) ?? 0;
        if (position & Node.DOCUMENT_POSITION_PRECEDING) return 1;
        if (position & Node.DOCUMENT_POSITION_FOLLOWING) return -1;
        return 0;
    });
    return { visibleSegments: mergedSegments, mergedCount };
};

const orderedSeedWindowForVisibleBounds = (segmentNodes, visibleBounds, {
    margin = 6,
} = {}) => {
    if (!Array.isArray(segmentNodes) || segmentNodes.length === 0 || !visibleBounds) {
        return null;
    }
    const rectCache = new Map();
    const rectByNode = new Map();
    let rectMeasureCount = 0;
    let rectMeasureElapsedMs = 0;
    let binaryProbeCount = 0;
    let forwardScanCount = 0;
    const positionCounts = {
        before: 0,
        intersects: 0,
        after: 0,
        unknown: 0,
    };
    const rectForIndex = (index) => {
        if (!Number.isFinite(index) || index < 0 || index >= segmentNodes.length) {
            return null;
        }
        if (rectCache.has(index)) {
            return rectCache.get(index);
        }
        const startedAt = performance.now();
        const rect = positiveBoundingClientRectForNode(segmentNodes[index]);
        rectMeasureElapsedMs += performance.now() - startedAt;
        rectMeasureCount += 1;
        rectCache.set(index, rect);
        if (segmentNodes[index]) {
            rectByNode.set(segmentNodes[index], rect);
        }
        return rect;
    };
    const positionForRect = (rect) => {
        if (!rect) return 'unknown';
        if (rect.bottom <= visibleBounds.top) return 'before';
        if (rect.top >= visibleBounds.bottom) return 'after';
        if (rect.right <= visibleBounds.left) return 'before';
        if (rect.left >= visibleBounds.right) return 'after';
        return 'intersects';
    };
    let low = 0;
    let high = segmentNodes.length - 1;
    let firstCandidateIndex = segmentNodes.length;
    while (low <= high) {
        const mid = Math.floor((low + high) / 2);
        const position = positionForRect(rectForIndex(mid));
        binaryProbeCount += 1;
        positionCounts[position] = (positionCounts[position] ?? 0) + 1;
        if (position === 'before') {
            low = mid + 1;
        } else {
            firstCandidateIndex = mid;
            high = mid - 1;
        }
    }
    if (firstCandidateIndex >= segmentNodes.length) {
        return {
            segmentNodes: [],
            rectCache,
            rectMeasureCount,
            rectMeasureElapsedMs,
            binaryProbeCount,
            forwardScanCount,
            firstCandidateIndex,
            firstAfterIndex: null,
            beforeProbeCount: positionCounts.before,
            intersectProbeCount: positionCounts.intersects,
            afterProbeCount: positionCounts.after,
            unknownProbeCount: positionCounts.unknown,
            windowStart: segmentNodes.length,
            windowEnd: segmentNodes.length - 1,
        };
    }
    const normalizedMargin = Number.isFinite(margin) && margin > 0 ? Math.floor(margin) : 0;
    let windowStart = Math.max(0, firstCandidateIndex - normalizedMargin);
    let scanEnd = firstCandidateIndex;
    while (scanEnd < segmentNodes.length) {
        const position = positionForRect(rectForIndex(scanEnd));
        forwardScanCount += 1;
        positionCounts[position] = (positionCounts[position] ?? 0) + 1;
        if (position === 'after') {
            break;
        }
        scanEnd += 1;
    }
    const windowEnd = Math.min(segmentNodes.length - 1, scanEnd + normalizedMargin);
    return {
        segmentNodes: segmentNodes.slice(windowStart, windowEnd + 1),
        rectCache,
        rectByNode,
        rectMeasureCount,
        rectMeasureElapsedMs,
        binaryProbeCount,
        forwardScanCount,
        firstCandidateIndex,
        firstAfterIndex: scanEnd < segmentNodes.length ? scanEnd : null,
        beforeProbeCount: positionCounts.before,
        intersectProbeCount: positionCounts.intersects,
        afterProbeCount: positionCounts.after,
        unknownProbeCount: positionCounts.unknown,
        windowStart,
        windowEnd,
    };
};

const collectExpandedRangeSegments = (doc, visibleRange, visibleBounds, {
    includeClientRects = true,
    bootstrap = null,
} = {}) => {
    if (!visibleRange || visibleRange.collapsed === true) {
        return null;
    }
    const isEbookDoc = isEbookContentDocument(doc);
    bootstrap = bootstrap || segmentMetadataBootstrap(doc);
    const rangeCommonAncestor = visibleRange.commonAncestorContainer?.nodeType === Node.ELEMENT_NODE
        ? visibleRange.commonAncestorContainer
        : visibleRange.commonAncestorContainer?.parentElement;
    const rangeSegmentNodes = isBroadEbookRangeRoot(rangeCommonAncestor, doc)
        ? null
        : collectSegmentNodesInVisibleRange(visibleRange);
    if (rangeSegmentNodes?.length > 0 && (!isEbookDoc || rangeSegmentNodes.length > 4)) {
        return {
            ...measureVisibleSegmentsInWindow(rangeSegmentNodes, visibleRange, visibleBounds, {
                assumeInVisibleRange: true,
                includeClientRects,
                bootstrap,
            }),
            segmentNodes: rangeSegmentNodes,
            segmentCandidateSource: 'sentinel-range',
            orderedSegmentCount: rangeSegmentNodes.length,
            boundedByWindow: true,
        };
    }
    const orderedSegments = orderedSegmentNodesForDocument(doc);
    const allSegmentNodes = orderedSegments.nodes;
    if (allSegmentNodes.length === 0) {
        return null;
    }
    const startIndex = rangeBoundarySegmentIndex(visibleRange, 'start', orderedSegments);
    const endIndex = rangeBoundarySegmentIndex(visibleRange, 'end', orderedSegments);
    if (!Number.isFinite(startIndex) && !Number.isFinite(endIndex)) {
        return null;
    }
    const anchorStart = Math.max(0, Math.min(startIndex ?? endIndex, endIndex ?? startIndex));
    const anchorEnd = Math.min(allSegmentNodes.length - 1, Math.max(startIndex ?? endIndex, endIndex ?? startIndex));
    if (isEbookDoc) {
        const rangeMargin = 12;
        const windowStart = Math.max(0, anchorStart - rangeMargin);
        const windowEnd = Math.min(allSegmentNodes.length - 1, anchorEnd + rangeMargin);
        const segmentNodes = allSegmentNodes.slice(windowStart, windowEnd + 1);
        const measured = measureVisibleSegmentsInWindow(segmentNodes, visibleRange, visibleBounds, {
            assumeInVisibleRange: false,
            includeClientRects,
            bootstrap,
        });
        if (measured.visibleSegments.length > 0) {
            return {
                ...measured,
                segmentNodes,
                segmentCandidateSource: 'page-sentinel-range-window',
                orderedSegmentCount: allSegmentNodes.length,
                anchorStart,
                anchorEnd,
                windowStart,
                windowEnd,
                expansionSize: rangeMargin,
                firstVisibleIndex: windowStart,
                lastVisibleIndex: windowEnd,
                boundedByWindow: true,
            };
        }
    }
    const fullDocumentExpansion = Math.max(anchorStart, allSegmentNodes.length - 1 - anchorEnd);
    const expansionSeeds = isEbookDoc
        ? [64, 128, 256, 512, 1024, 2048, fullDocumentExpansion]
        : [32, 64, 128, 256, 512, fullDocumentExpansion];
    const expansionSizes = Array.from(new Set(expansionSeeds))
        .filter((value) => Number.isFinite(value) && value >= 0);
    let best = null;
    for (const expansionSize of expansionSizes) {
        const windowStart = Math.max(0, anchorStart - expansionSize);
        const windowEnd = Math.min(allSegmentNodes.length - 1, anchorEnd + expansionSize);
        const segmentNodes = allSegmentNodes.slice(windowStart, windowEnd + 1);
        const measured = measureVisibleSegmentsInWindow(segmentNodes, visibleRange, visibleBounds, {
            assumeInVisibleRange: isEbookDoc,
            includeClientRects,
            bootstrap,
        });
        const visibleIndexes = measured.visibleSegments
            .map((item) => orderedSegments.indexByNode.get(item.node))
            .filter((index) => Number.isFinite(index));
        const firstVisibleIndex = visibleIndexes.length > 0 ? Math.min(...visibleIndexes) : null;
        const lastVisibleIndex = visibleIndexes.length > 0 ? Math.max(...visibleIndexes) : null;
        const hasLeadingMargin = firstVisibleIndex !== null && (firstVisibleIndex > windowStart || windowStart === 0);
        const hasTrailingMargin = lastVisibleIndex !== null && (lastVisibleIndex < windowEnd || windowEnd === allSegmentNodes.length - 1);
        best = {
            ...measured,
            segmentNodes,
            segmentCandidateSource: 'range-window',
            orderedSegmentCount: allSegmentNodes.length,
            anchorStart,
            anchorEnd,
            windowStart,
            windowEnd,
            expansionSize,
            firstVisibleIndex,
            lastVisibleIndex,
            boundedByWindow: hasLeadingMargin && hasTrailingMargin,
        };
        if (best.visibleSegments.length > 0 && best.boundedByWindow) {
            return best;
        }
        if (isEbookDoc && best.visibleSegments.length >= 48 && expansionSize >= 512) {
            return best;
        }
    }
    return best?.visibleSegments?.length > 0 ? best : null;
};

const collectVisibleSegmentNodesFromRange = (doc, visibleRange = null, {
    includeClientRects = true,
    includeSegmentMetadata = true,
    reason = 'visible-segments',
    viewportSampleDensity = null,
    minimumViewportSampleSegmentCount = 0,
    seedSegmentNodes = null,
    seedSegmentSource = null,
    useOrderedDocumentWindow = false,
} = {}) => {
    if (!isDocumentLike(doc)) {
        return {
            visibleSegments: [],
            viewportWidth: 0,
            viewportHeight: 0,
            viewportLeft: 0,
            viewportTop: 0,
            frameLeft: 0,
            frameTop: 0,
            containerLeft: null,
            containerTop: null,
            hasExpectedPaginatorContainer: false,
            totalSegmentCount: 0,
            hiddenTooltipCount: 0,
            missingIdentifierCount: 0,
            outOfViewportCount: 0,
        };
    }
    const startedAt = performance.now();
    const {
        viewportWidth,
        viewportHeight,
        viewportLeft,
        viewportTop,
        visibleBounds,
        frameRect,
        containerRect,
        hasExpectedPaginatorContainer,
    } = viewportBoundsForReaderDocument(doc);
    const isEbookDoc = isEbookContentDocument(doc);
    const useVisibleRange = !!visibleRange && visibleRange.collapsed !== true;
    const useViewportFallback = !useVisibleRange;
    const rangeCommonAncestor = visibleRange?.commonAncestorContainer ?? null;
    const rangeCommonAncestorElement = rangeCommonAncestor?.nodeType === Node.ELEMENT_NODE
        ? rangeCommonAncestor
        : (rangeCommonAncestor?.parentElement || null);
    const isBroadEbookRangeAncestor = isEbookDoc && useVisibleRange && isBroadEbookRangeRoot(rangeCommonAncestorElement, doc);
    const normalizedViewportSampleDensity =
        viewportSampleDensity === 'minimal'
        || viewportSampleDensity === 'sparse'
        || viewportSampleDensity === 'status'
        || viewportSampleDensity === 'normal'
            ? viewportSampleDensity
            : null;
    const normalizedMinimumViewportSampleSegmentCount =
        Number.isFinite(minimumViewportSampleSegmentCount) && minimumViewportSampleSegmentCount > 0
            ? minimumViewportSampleSegmentCount
            : 0;
    const normalizedSeedSegmentNodes = Array.isArray(seedSegmentNodes)
        ? seedSegmentNodes.filter((node) => node?.matches?.(manabiReaderSegmentSelector) === true)
        : [];
    const seedSegmentSignature = normalizedSeedSegmentNodes.length > 0
        ? [
            seedSegmentSource || 'seed',
            normalizedSeedSegmentNodes.length,
            normalizedSeedSegmentNodes[0]?.id || '',
            normalizedSeedSegmentNodes[normalizedSeedSegmentNodes.length - 1]?.id || '',
        ].join(':')
        : null;
    const minimumEbookViewportSampleSegmentCount = Math.max(8, normalizedMinimumViewportSampleSegmentCount);
    const collectionCacheKey = visibleSegmentCollectionCacheKey(doc, visibleRange, visibleBounds, {
        includeClientRects,
        includeSegmentMetadata,
        viewportSampleDensity: normalizedViewportSampleDensity,
        minimumViewportSampleSegmentCount: normalizedMinimumViewportSampleSegmentCount,
        seedSegmentSignature,
        useOrderedDocumentWindow,
    });
    const cachedCollection = cachedVisibleSegmentCollection(doc, collectionCacheKey);
    if (cachedCollection) {
        manabiTimelineMeasure('visibleSegments.collect.cache', startedAt, {
            source: cachedCollection?.segmentCandidateSource ?? null,
            reason,
            includeClientRects,
            visibleSegmentCount: cachedCollection?.visibleSegments?.length ?? 0,
        }, 50);
        return cachedCollection;
    }
    // A renderability-only probe needs a runtime DOM ID, not durable lookup
    // identity. Avoid expanding the whole external sidecar until lookup/status
    // enrichment actually asks for metadata.
    const bootstrap = includeSegmentMetadata
        ? segmentMetadataBootstrap(doc)
        : emptySegmentMetadataBootstrap();
    const expandedRangeResult = useVisibleRange
        ? collectExpandedRangeSegments(doc, visibleRange, visibleBounds, { includeClientRects, bootstrap })
        : null;
    const orderedDocumentWindowCandidate = isEbookDoc
        && useOrderedDocumentWindow === true
        && !expandedRangeResult
        && normalizedSeedSegmentNodes.length === 0
        && !!visibleBounds
        ? orderedSeedWindowForVisibleBounds(orderedSegmentNodesForDocument(doc).nodes, visibleBounds, { margin: 8 })
        : null;
    const orderedDocumentWindow = (orderedDocumentWindowCandidate?.segmentNodes?.length ?? 0) > 0
        ? orderedDocumentWindowCandidate
        : null;
    let viewportSample = null;
    const shouldSampleEbookViewport =
        isEbookDoc
        && !!visibleBounds
        && !orderedDocumentWindow
        && (!expandedRangeResult || (expandedRangeResult.visibleSegments?.length ?? 0) < minimumEbookViewportSampleSegmentCount);
    const shouldSampleViewport = !!visibleBounds && (!useVisibleRange || shouldSampleEbookViewport);
    if (shouldSampleViewport) {
        const primarySampleDensity = normalizedViewportSampleDensity || (shouldSampleEbookViewport ? 'normal' : 'sparse');
        const seedNodes = isEbookDoc && normalizedSeedSegmentNodes.length > 0
            ? normalizedSeedSegmentNodes
            : null;
        const sparseNodes = seedNodes ?? collectViewportSampleSegmentNodes(doc, visibleBounds, { sampleDensity: primarySampleDensity });
        viewportSample = sparseNodes?.length > 0
            ? {
                nodes: sparseNodes,
                source: seedNodes ? (seedSegmentSource || 'seed-segments') : `viewport-sample-${primarySampleDensity}`,
                trustVisible: !seedNodes,
            }
            : null;
        if (
            isEbookDoc
            && !seedNodes
            && (primarySampleDensity === 'sparse' || primarySampleDensity === 'status')
            && (sparseNodes?.length ?? 0) < normalizedMinimumViewportSampleSegmentCount
        ) {
            const expandedNodes = collectViewportSampleSegmentNodes(doc, visibleBounds, { sampleDensity: 'normal' });
            viewportSample = expandedNodes?.length > 0
                ? { nodes: expandedNodes, source: 'viewport-sample-normal', trustVisible: true }
                : viewportSample;
        }
        if (!viewportSample && !isEbookDoc) {
            const expandedNodes = collectViewportSampleSegmentNodes(doc, visibleBounds, { sampleDensity: 'normal' });
            viewportSample = expandedNodes?.length > 0
                ? { nodes: expandedNodes, source: 'viewport-sample-expanded', trustVisible: true }
                : null;
        }
    }
    const viewportSampleSegmentNodes = viewportSample?.nodes ?? null;
    const orderedSeedWindow = isEbookDoc
        && !expandedRangeResult
        && (
            !!orderedDocumentWindow
            || (
                viewportSampleSegmentNodes?.length > 0
                && viewportSample?.trustVisible === false
            )
        )
        && !!visibleBounds
        ? (orderedDocumentWindow ?? orderedSeedWindowForVisibleBounds(viewportSampleSegmentNodes, visibleBounds, { margin: 8 }))
        : null;
    const boundedSegmentNodes = expandedRangeResult?.segmentNodes ?? orderedSeedWindow?.segmentNodes ?? viewportSampleSegmentNodes ?? null;
    const shouldUseRangeAncestorFallback = !isEbookDoc
        && useVisibleRange
        && !expandedRangeResult
        && !viewportSampleSegmentNodes
        && rangeCommonAncestorElement?.querySelectorAll
        && !isBroadEbookRangeAncestor;
    const segmentSearchRoot = shouldUseRangeAncestorFallback
        ? rangeCommonAncestorElement
        : doc;
    const allSegmentNodes = boundedSegmentNodes || (isEbookDoc && segmentSearchRoot === doc ? [] : [
            ...(segmentSearchRoot.matches?.(manabiReaderSegmentSelector) ? [segmentSearchRoot] : []),
            ...Array.from(segmentSearchRoot.querySelectorAll?.('m-m') ?? []),
        ]);
    const shouldTrustEbookViewportSample = isEbookDoc
        && !!viewportSampleSegmentNodes
        && boundedSegmentNodes === viewportSampleSegmentNodes
        && viewportSample?.trustVisible !== false;
    const queryCompletedAt = performance.now();
    const ancestorSegmentCandidateCount = segmentSearchRoot === rangeCommonAncestorElement
        ? allSegmentNodes.length
        : null;
    const segmentCandidateSource = expandedRangeResult?.segmentCandidateSource
        || (orderedDocumentWindow ? 'ordered-document-window' : null)
        || viewportSample?.source
        || (isBroadEbookRangeAncestor ? 'ebook-broad-range-empty' : null)
        || (isEbookDoc && segmentSearchRoot === doc ? 'ebook-bounded-empty' : null)
        || (segmentSearchRoot === doc ? 'document' : 'range-ancestor');
    const visibleSegments = expandedRangeResult?.visibleSegments ? [...expandedRangeResult.visibleSegments] : [];
    let totalSegmentCount = expandedRangeResult ? allSegmentNodes.length : 0;
    let hiddenTooltipCount = expandedRangeResult?.hiddenTooltipCount ?? 0;
    let missingIdentifierCount = expandedRangeResult?.missingIdentifierCount ?? 0;
    let outOfViewportCount = expandedRangeResult?.outOfViewportCount ?? 0;
    let visibleRangeCheckCount = expandedRangeResult?.visibleRangeCheckCount ?? 0;
    let visibleRangeErrorCount = expandedRangeResult?.visibleRangeErrorCount ?? 0;
    let rectMeasureCount = (expandedRangeResult?.rectMeasureCount ?? 0) + (orderedSeedWindow?.rectMeasureCount ?? 0);
    let rectMeasureElapsedMs = (expandedRangeResult?.rectMeasureElapsedMs ?? 0) + (orderedSeedWindow?.rectMeasureElapsedMs ?? 0);
    let rangeCheckElapsedMs = expandedRangeResult?.rangeCheckElapsedMs ?? 0;
    let viewportSampleMeasuredCount = 0;
    let viewportSampleMergedCount = 0;
    let seedWindowRectCacheHitCount = 0;
    let finalLoopRectMeasureCount = 0;
    let finalLoopRectMeasureElapsedMs = 0;
    if (orderedSeedWindow && typeof manabiTimelineMark === 'function') {
        manabiTimelineMark('visibleSegments.seedWindow', {
            reason,
            source: viewportSample?.source ?? null,
            seedSegmentSource: seedSegmentSignature ? (seedSegmentSource || 'seed') : null,
            seedSegmentCount: normalizedSeedSegmentNodes.length,
            viewportSampleCount: viewportSampleSegmentNodes?.length ?? 0,
            windowStart: orderedSeedWindow.windowStart,
            windowEnd: orderedSeedWindow.windowEnd,
            windowCount: orderedSeedWindow.segmentNodes?.length ?? 0,
            binaryProbeCount: orderedSeedWindow.binaryProbeCount ?? 0,
            forwardScanCount: orderedSeedWindow.forwardScanCount ?? 0,
            firstCandidateIndex: orderedSeedWindow.firstCandidateIndex ?? null,
            firstAfterIndex: orderedSeedWindow.firstAfterIndex ?? null,
            beforeProbeCount: orderedSeedWindow.beforeProbeCount ?? 0,
            intersectProbeCount: orderedSeedWindow.intersectProbeCount ?? 0,
            afterProbeCount: orderedSeedWindow.afterProbeCount ?? 0,
            unknownProbeCount: orderedSeedWindow.unknownProbeCount ?? 0,
            rectMeasureCount: orderedSeedWindow.rectMeasureCount ?? 0,
            rectMeasureElapsedMs: orderedSeedWindow.rectMeasureElapsedMs ?? 0,
        });
    }
    if (expandedRangeResult && viewportSampleSegmentNodes?.length > 0) {
        const viewportMeasured = measureVisibleSegmentsInWindow(viewportSampleSegmentNodes, visibleRange, visibleBounds, {
            assumeInVisibleRange: true,
            includeClientRects,
            bootstrap,
        });
        viewportSampleMeasuredCount = viewportMeasured.visibleSegments.length;
        totalSegmentCount += viewportSampleSegmentNodes.length;
        hiddenTooltipCount += viewportMeasured.hiddenTooltipCount;
        missingIdentifierCount += viewportMeasured.missingIdentifierCount;
        outOfViewportCount += viewportMeasured.outOfViewportCount;
        visibleRangeCheckCount += viewportMeasured.visibleRangeCheckCount;
        visibleRangeErrorCount += viewportMeasured.visibleRangeErrorCount;
        rectMeasureCount += viewportMeasured.rectMeasureCount;
        rectMeasureElapsedMs += viewportMeasured.rectMeasureElapsedMs;
        rangeCheckElapsedMs += viewportMeasured.rangeCheckElapsedMs;
        const merged = mergeMeasuredVisibleSegments(visibleSegments, viewportMeasured.visibleSegments);
        visibleSegments.length = 0;
        visibleSegments.push(...merged.visibleSegments);
        viewportSampleMergedCount = merged.mergedCount;
    }
    for (const segmentNode of expandedRangeResult ? [] : allSegmentNodes) {
        totalSegmentCount += 1;
        if (segmentNode.closest('.tippy-box')) {
            hiddenTooltipCount += 1;
            continue;
        }
        const segmentMetadata = segmentMetadataForNode(segmentNode, bootstrap);
        const segmentIdentifier = segmentIdentifierForNode(segmentNode, bootstrap, segmentMetadata);
        if (!segmentIdentifier) {
            missingIdentifierCount += 1;
            continue;
        }
        const rectStartedAt = performance.now();
        let measuredBoundingRect = null;
        if (isEbookDoc && viewportSample?.trustVisible === false && !!visibleBounds) {
            const hasCachedSeedWindowRect = orderedSeedWindow?.rectByNode?.has?.(segmentNode) === true;
            measuredBoundingRect = hasCachedSeedWindowRect
                ? orderedSeedWindow.rectByNode.get(segmentNode)
                : positiveBoundingClientRectForNode(segmentNode);
            if (hasCachedSeedWindowRect) {
                seedWindowRectCacheHitCount += 1;
            } else {
                rectMeasureCount += 1;
                finalLoopRectMeasureCount += 1;
            }
            if (!rectIntersectsBounds(measuredBoundingRect, visibleBounds)) {
                const elapsed = performance.now() - rectStartedAt;
                rectMeasureElapsedMs += elapsed;
                finalLoopRectMeasureElapsedMs += elapsed;
                outOfViewportCount += 1;
                continue;
            }
        }
        const { rect, rects } = measuredVisibleRectsForSegmentNode(segmentNode, visibleBounds, {
            assumeInVisibleRange: shouldTrustEbookViewportSample,
            includeClientRects,
            measuredBoundingRect,
        });
        if (!measuredBoundingRect) {
            rectMeasureCount += 1;
            finalLoopRectMeasureCount += 1;
        }
        const rectElapsed = performance.now() - rectStartedAt;
        rectMeasureElapsedMs += rectElapsed;
        finalLoopRectMeasureElapsedMs += rectElapsed;
        const isInVisibleRange = shouldTrustEbookViewportSample
            ? !!rect
            : useVisibleRange
            ? (() => {
                const rangeStartedAt = performance.now();
                try {
                    visibleRangeCheckCount += 1;
                    const didIntersect = visibleRange.intersectsNode(segmentNode);
                    rangeCheckElapsedMs += performance.now() - rangeStartedAt;
                    return didIntersect;
                } catch (_error) {
                    visibleRangeErrorCount += 1;
                    rangeCheckElapsedMs += performance.now() - rangeStartedAt;
                    return false;
                }
            })()
            : (useViewportFallback && !!rect);
        if (!isInVisibleRange) {
            outOfViewportCount += 1;
            continue;
        }
        const sentenceNode = segmentNode.closest(manabiReaderSentenceSelector);
        visibleSegments.push({
            node: segmentNode,
            rect,
            rects,
            segmentIdentifier,
            segmentIdentifierAliases: segmentIdentifierAliasesForNode(segmentNode, bootstrap, segmentMetadata),
            sentenceIdentifier: sentenceIdentifierForNode(sentenceNode),
            segmentMetadata,
        });
    }
    const completedAt = performance.now();
    manabiTimelineMeasure('visibleSegments.collect', startedAt, {
        source: segmentCandidateSource,
        reason,
        includeClientRects,
        viewportSampleDensity: normalizedViewportSampleDensity,
        minimumViewportSampleSegmentCount: normalizedMinimumViewportSampleSegmentCount,
        seedSegmentSource: seedSegmentSignature ? (seedSegmentSource || 'seed') : null,
        seedSegmentCount: normalizedSeedSegmentNodes.length,
        useVisibleRange,
        totalSegmentCount,
        visibleSegmentCount: visibleSegments.length,
        viewportSampleCount: viewportSampleSegmentNodes?.length ?? 0,
        viewportSampleMeasuredCount,
        viewportSampleMergedCount,
        seedWindowStart: orderedSeedWindow?.windowStart ?? null,
        seedWindowEnd: orderedSeedWindow?.windowEnd ?? null,
        seedWindowCount: orderedSeedWindow?.segmentNodes?.length ?? null,
        seedWindowBinaryProbeCount: orderedSeedWindow?.binaryProbeCount ?? null,
        seedWindowForwardScanCount: orderedSeedWindow?.forwardScanCount ?? null,
        seedWindowFirstCandidateIndex: orderedSeedWindow?.firstCandidateIndex ?? null,
        seedWindowFirstAfterIndex: orderedSeedWindow?.firstAfterIndex ?? null,
        seedWindowBeforeProbeCount: orderedSeedWindow?.beforeProbeCount ?? null,
        seedWindowIntersectProbeCount: orderedSeedWindow?.intersectProbeCount ?? null,
        seedWindowAfterProbeCount: orderedSeedWindow?.afterProbeCount ?? null,
        seedWindowUnknownProbeCount: orderedSeedWindow?.unknownProbeCount ?? null,
        seedWindowRectMeasureCount: orderedSeedWindow?.rectMeasureCount ?? null,
        seedWindowRectMeasureElapsedMs: orderedSeedWindow?.rectMeasureElapsedMs ?? null,
        seedWindowRectCacheHitCount,
        finalLoopRectMeasureCount,
        finalLoopRectMeasureElapsedMs,
        rectMeasureCount,
        useOrderedDocumentWindow,
        hiddenTooltipCount,
        missingIdentifierCount,
        outOfViewportCount,
        queryElapsedMs: queryCompletedAt - startedAt,
        rectMeasureElapsedMs,
        rangeCheckElapsedMs,
        broadEbookRangeAncestor: isBroadEbookRangeAncestor,
    }, 100);
    const result = {
        visibleSegments,
        viewportWidth,
        viewportHeight,
        viewportLeft,
        viewportTop,
        frameLeft: Number.isFinite(frameRect?.left) ? frameRect.left : 0,
        frameTop: Number.isFinite(frameRect?.top) ? frameRect.top : 0,
        frameWidth: Number.isFinite(frameRect?.width) ? frameRect.width : null,
        frameHeight: Number.isFinite(frameRect?.height) ? frameRect.height : null,
        containerLeft: Number.isFinite(containerRect?.left) ? containerRect.left : null,
        containerTop: Number.isFinite(containerRect?.top) ? containerRect.top : null,
        containerWidth: Number.isFinite(containerRect?.width) ? containerRect.width : null,
        containerHeight: Number.isFinite(containerRect?.height) ? containerRect.height : null,
        hasExpectedPaginatorContainer,
        totalSegmentCount,
        segmentCandidateSource,
        viewportSampleCount: viewportSampleSegmentNodes?.length ?? 0,
        viewportSampleMeasuredCount,
        viewportSampleMergedCount,
        seedWindowStart: orderedSeedWindow?.windowStart ?? null,
        seedWindowEnd: orderedSeedWindow?.windowEnd ?? null,
        seedWindowCount: orderedSeedWindow?.segmentNodes?.length ?? null,
        seedWindowBinaryProbeCount: orderedSeedWindow?.binaryProbeCount ?? null,
        seedWindowForwardScanCount: orderedSeedWindow?.forwardScanCount ?? null,
        seedWindowFirstCandidateIndex: orderedSeedWindow?.firstCandidateIndex ?? null,
        seedWindowFirstAfterIndex: orderedSeedWindow?.firstAfterIndex ?? null,
        seedWindowBeforeProbeCount: orderedSeedWindow?.beforeProbeCount ?? null,
        seedWindowIntersectProbeCount: orderedSeedWindow?.intersectProbeCount ?? null,
        seedWindowAfterProbeCount: orderedSeedWindow?.afterProbeCount ?? null,
        seedWindowUnknownProbeCount: orderedSeedWindow?.unknownProbeCount ?? null,
        seedWindowRectMeasureCount: orderedSeedWindow?.rectMeasureCount ?? null,
        seedWindowRectMeasureElapsedMs: orderedSeedWindow?.rectMeasureElapsedMs ?? null,
        seedWindowRectCacheHitCount,
        finalLoopRectMeasureCount,
        finalLoopRectMeasureElapsedMs,
        rectMeasureCount,
        useOrderedDocumentWindow,
        hiddenTooltipCount,
        missingIdentifierCount,
        outOfViewportCount,
        includeClientRects,
        includesSegmentMetadata: includeSegmentMetadata,
        segmentMetadataBootstrap: bootstrap,
    };
    cacheVisibleSegmentCollection(doc, collectionCacheKey, result);
    return result;
};

const visiblePageSegmentCollectionModes = Object.freeze({
    initialRenderableProbe: Object.freeze({
        includeClientRects: false,
        includeSegmentMetadata: false,
        postLookupTargets: false,
        prepareLookupIndex: false,
        hydrateStatuses: false,
        viewportSampleDensity: 'minimal',
        minimumViewportSampleSegmentCount: 1,
        useOrderedDocumentWindow: false,
        includeLookupSurfaceText: false,
    }),
    pageTurnLookupTargets: Object.freeze({
        includeClientRects: false,
        postLookupTargets: true,
        prepareLookupIndex: true,
        hydrateStatuses: false,
        viewportSampleDensity: 'status',
        minimumViewportSampleSegmentCount: 8,
        includeLookupSurfaceText: false,
    }),
    pageTurnStatusHydration: Object.freeze({
        includeClientRects: false,
        postLookupTargets: true,
        prepareLookupIndex: true,
        hydrateStatuses: true,
        hydrateStatusesSynchronously: true,
        viewportSampleDensity: 'status',
        minimumViewportSampleSegmentCount: 8,
        includeLookupSurfaceText: false,
    }),
    visibleStatusRefresh: Object.freeze({
        includeClientRects: false,
        postLookupTargets: false,
        prepareLookupIndex: true,
        hydrateStatuses: true,
        viewportSampleDensity: 'status',
        minimumViewportSampleSegmentCount: 8,
        includeLookupSurfaceText: false,
    }),
    fullLookupRefresh: Object.freeze({
        includeClientRects: true,
        postLookupTargets: true,
        prepareLookupIndex: true,
        hydrateStatuses: true,
        includeLookupSurfaceText: true,
    }),
});

const visiblePageSegmentCollectionOptions = (modeName = null, overrides = {}) => ({
    ...(modeName && visiblePageSegmentCollectionModes[modeName] ? visiblePageSegmentCollectionModes[modeName] : {}),
    ...(overrides || {}),
});

const renderableContentProbeResultForDocument = (doc, visibleRange = null, reason = 'initial-renderable-probe') =>
    collectVisibleSegmentNodesFromRange(doc, visibleRange, {
        ...visiblePageSegmentCollectionModes.initialRenderableProbe,
        reason,
    });

const buildVisiblePageLookupIndex = (doc, visibleSegmentsResult, reason = 'unspecified', {
    includeSurfaceText = true,
} = {}) => {
    const startedAt = performanceNowMs();
    prepareVisibleSegmentsResult(visibleSegmentsResult, doc);
    const byElementID = new Map();
    const bySegmentIdentifier = new Map();
    const idsByEntryID = new Map();
    const trackingPayloadByElementID = new Map();
    const visibleElementIDs = [];
    const visibleSegments = Array.isArray(visibleSegmentsResult?.visibleSegments)
        ? visibleSegmentsResult.visibleSegments
        : [];
    const indexedNodes = new Set();
    const sentenceIdentifiers = new Set();
    const surfaceTextForLookupSegment = (node) => {
        const surfaceText = Array.from(node?.querySelectorAll?.(manabiReaderSurfaceSelector) ?? [])
            .map(surfaceElement => surfaceElement.textContent || '')
            .join('');
        return surfaceText || null;
    };
    const addMetadataAlias = (metadata, alias) => {
        if (typeof alias !== 'string' || alias.length === 0) return;
        bySegmentIdentifier.set(alias, metadata);
    };
    const addEntryIDs = (segmentID, entryIDs) => {
        if (typeof segmentID !== 'string' || segmentID.length === 0 || !Array.isArray(entryIDs)) return;
        for (const entryID of entryIDs) {
            if (!Number.isFinite(entryID)) continue;
            const key = String(entryID);
            if (!idsByEntryID.has(key)) idsByEntryID.set(key, new Set());
            idsByEntryID.get(key).add(segmentID);
        }
    };
    const indexSegmentNode = (node, item = null, source = 'visible') => {
        if (!node || indexedNodes.has(node)) return;
        indexedNodes.add(node);
        const elementID = node.id || node.getAttribute?.('id') || null;
        const sourceMetadata = item?.segmentMetadata || segmentMetadataForNode(node, visibleSegmentsResult?.segmentMetadataBootstrap) || {};
        const sentenceNode = node.closest?.(manabiReaderSentenceSelector) || null;
        const sentenceIdentifier = item?.sentenceIdentifier
            || sentenceIdentifierForNode(sentenceNode)
            || sourceMetadata.sentenceID
            || null;
        if (typeof sentenceIdentifier === 'string' && sentenceIdentifier.length > 0) {
            sentenceIdentifiers.add(sentenceIdentifier);
        }
        const stableSegmentIdentifier = typeof sourceMetadata.sid === 'string' && sourceMetadata.sid.length > 0
            ? sourceMetadata.sid
            : null;
        const segmentIdentifier = segmentIdentifierForNode(
            node,
            visibleSegmentsResult?.segmentMetadataBootstrap,
            sourceMetadata
        );
        if (!segmentIdentifier) { return; }
        const metadata = {
            ...sourceMetadata,
            i: sourceMetadata.i || elementID,
            h: sourceMetadata.h || null,
            sid: sourceMetadata.sid || stableSegmentIdentifier,
            sentenceID: sourceMetadata.sentenceID || sentenceIdentifier,
            sentenceIdentifier,
            segmentIdentifier,
            visibleIndexSource: source,
            x: sourceMetadata.x || (includeSurfaceText ? surfaceTextForLookupSegment(node) : null),
        };
        if (elementID) {
            byElementID.set(elementID, metadata);
        }
        addMetadataAlias(metadata, segmentIdentifier);
        addMetadataAlias(metadata, metadata.sid);
        for (const alias of item?.segmentIdentifierAliases || []) {
            addMetadataAlias(metadata, alias);
        }
        const entryIndexID = metadata.i || elementID || segmentIdentifier;
        const jmdictEntryIDs = item?.jmdictEntryIDs || segmentEntryIDsForMetadata(metadata, 'jmdict');
        const jmnedictEntryIDs = item?.jmnedictEntryIDs || segmentEntryIDsForMetadata(metadata, 'jmnedict');
        const primaryEntryIDs = item?.primaryEntryIDs || (jmdictEntryIDs.length ? jmdictEntryIDs : jmnedictEntryIDs);
        addEntryIDs(entryIndexID, jmdictEntryIDs);
        addEntryIDs(entryIndexID, jmnedictEntryIDs);
        addEntryIDs(metadata.sid, jmdictEntryIDs);
        addEntryIDs(metadata.sid, jmnedictEntryIDs);
        if (elementID) {
            trackingPayloadByElementID.set(elementID, {
                elementID,
                segmentIdentifier,
                sentenceIdentifier,
                metadata,
                jmdictEntryIDs,
                jmnedictEntryIDs,
                primaryEntryIDs,
            });
        }
    };
    for (const item of visibleSegments) {
        const node = item?.node ?? null;
        const elementID = node?.id || node?.getAttribute?.('id') || null;
        if (elementID) {
            visibleElementIDs.push(elementID);
        }
        indexSegmentNode(node, item, 'visible');
    }
    const index = {
        byElementID,
        bySegmentIdentifier,
        idsByEntryID,
        trackingPayloadByElementID,
        reason,
        visibleSegmentCount: visibleSegments.length,
        indexedSegmentCount: byElementID.size,
        sentenceIdentifierCount: sentenceIdentifiers.size,
        visibleElementIDs,
        builtAt: Date.now(),
    };
    if (doc) {
        doc.manabiVisiblePageLookupIndex = index;
        if (doc.defaultView) {
            doc.defaultView.__manabiVisiblePageLookupIndex = index;
            try {
                doc.defaultView.manabi_prepareVisiblePageLookupIndex?.(index);
            } catch (error) {
            }
        }
        requestNativeVisibleTrackedWordsPrime(doc, index, `visible-prime:${reason}`);
    }
    manabiTimelineMeasure('visibleLookup.index.built', startedAt, {
        reason,
        visibleSegmentCount: visibleSegments.length,
        indexedSegmentCount: byElementID.size,
        sentenceIdentifierCount: sentenceIdentifiers.size,
        elementIDCount: byElementID.size,
        aliasCount: bySegmentIdentifier.size,
        entryIDKeyCount: idsByEntryID.size,
        includeSurfaceText,
        firstVisibleElementID: visibleElementIDs[0] ?? null,
    }, 25);
    return index;
};

const nativeLookupSharedStylePayloadForDocument = (doc) => {
    const view = doc?.defaultView ?? null;
    const body = doc?.body ?? null;
    const root = doc?.documentElement ?? null;
    const target = body || root;
    if (!view || !target) {
        return null;
    }
    try {
        if (isEbookContentDocument(doc)) {
            const bodyDirection = body?.dataset?.mnbFoliateWritingDirection
                || body?.dataset?.mnbWritingDirection
                || null;
            const isVerticalWriting = body?.classList?.contains?.('reader-vertical-writing') === true
                || bodyDirection === 'vertical'
                || root?.classList?.contains?.('vrtl') === true;
            const isHorizontalWriting = bodyDirection === 'horizontal'
                || (!isVerticalWriting && root?.classList?.contains?.('hltr') === true);
            return {
                targetWritingMode: isVerticalWriting ? 'vertical-rl' : (isHorizontalWriting ? 'horizontal-tb' : null),
                targetDirection: null,
                bodyWritingMode: isVerticalWriting ? 'vertical-rl' : (isHorizontalWriting ? 'horizontal-tb' : null),
                bodyDirection: null,
                rootWritingMode: isVerticalWriting ? 'vertical-rl' : (isHorizontalWriting ? 'horizontal-tb' : null),
                rootDirection: null,
                isVerticalWriting,
                source: 'ebook-document-direction',
            };
        }
        const signature = [
            body?.className ?? '',
            body?.dataset?.mnbFoliateWritingDirection ?? '',
            body?.dataset?.mnbFoliateWritingMode ?? '',
            root?.className ?? '',
            body?.getAttribute?.('style') ?? '',
            root?.getAttribute?.('style') ?? '',
        ].join('|');
        if (doc.__manabiNativeLookupSharedStylePayloadCache?.signature === signature) {
            return doc.__manabiNativeLookupSharedStylePayloadCache.payload;
        }
        const targetStyle = view.getComputedStyle?.(target);
        const bodyStyle = body ? view.getComputedStyle?.(body) : targetStyle;
        const rootStyle = root ? view.getComputedStyle?.(root) : targetStyle;
        const payload = {
            targetWritingMode: targetStyle?.writingMode ?? null,
            targetDirection: targetStyle?.direction ?? null,
            bodyWritingMode: bodyStyle?.writingMode ?? null,
            bodyDirection: bodyStyle?.direction ?? null,
            rootWritingMode: rootStyle?.writingMode ?? null,
            rootDirection: rootStyle?.direction ?? null,
            isVerticalWriting: (
                body?.classList?.contains?.('reader-vertical-writing') === true
                || body?.dataset?.mnbFoliateWritingDirection === 'vertical'
                || root?.classList?.contains?.('vrtl') === true
                || targetStyle?.writingMode?.startsWith?.('vertical') === true
                || bodyStyle?.writingMode?.startsWith?.('vertical') === true
            ),
        };
        doc.__manabiNativeLookupSharedStylePayloadCache = { signature, payload };
        return payload;
    } catch (_error) {
        return null;
    }
};

const postNativeLookupHitTargetsForVisibleSegments = (doc, visibleSegmentsResult, reason = 'unspecified') => {
    const startedAt = performanceNowMs();
    const view = doc?.defaultView ?? null;
    const builder = view?.manabi_nativeLookupHitTargetForSegment ?? null;
    const nativeLookupFrameKey = doc?.location?.href || doc?.URL || null;
    const viewportWidth = visibleSegmentsResult?.viewportWidth
        ?? window.visualViewport?.width
        ?? window.innerWidth
        ?? document.documentElement?.clientWidth
        ?? null;
    const viewportHeight = visibleSegmentsResult?.viewportHeight
        ?? window.visualViewport?.height
        ?? window.innerHeight
        ?? document.documentElement?.clientHeight
        ?? null;
    const viewportLeft = visibleSegmentsResult?.viewportLeft ?? 0;
    const viewportTop = visibleSegmentsResult?.viewportTop ?? 0;
    const visualViewportScale = Number.isFinite(window.visualViewport?.scale) ? window.visualViewport.scale : 1;
    const frameLeft = visibleSegmentsResult?.frameLeft ?? 0;
    const frameTop = visibleSegmentsResult?.frameTop ?? 0;
    const viewportPayload = {
        visualViewportWidth: viewportWidth,
        visualViewportHeight: viewportHeight,
        visualViewportOffsetLeft: 0,
        visualViewportOffsetTop: 0,
        scale: visualViewportScale,
        pageLeft: Number.isFinite(window.visualViewport?.pageLeft) ? window.visualViewport.pageLeft : null,
        pageTop: Number.isFinite(window.visualViewport?.pageTop) ? window.visualViewport.pageTop : null,
        viewportLeft,
        viewportTop,
        // Captured in the same geometry pass as each local segment rect. This keeps content-range
        // fragments on the exact basis used for supplied rects without remeasuring a moving iframe.
        contentFrameLeft: frameLeft,
        contentFrameTop: frameTop,
        stylePayload: nativeLookupSharedStylePayloadForDocument(doc),
    };
    const messageHandlers = view?.webkit?.messageHandlers ?? window.webkit?.messageHandlers ?? null;
    if (typeof builder !== 'function') {
        manabiTimelineMeasure('nativeLookup.targets.post', startedAt, {
            reason,
            builder: false,
            visibleSegmentCount: visibleSegmentsResult?.visibleSegments?.length ?? 0,
            targetCount: 0,
            segmentSource: visibleSegmentsResult?.segmentCandidateSource ?? null,
            frameLeft: visibleSegmentsResult?.frameLeft ?? null,
            frameTop: visibleSegmentsResult?.frameTop ?? null,
            viewportWidth,
            viewportHeight,
        }, 100);
        return 0;
    }
    const targets = [];
    view?.manabi_resetNativeLookupHitTargets?.();
    for (const item of visibleSegmentsResult?.visibleSegments ?? []) {
        const rects = item?.rects?.length ? item.rects : (item?.rect ? [item.rect] : []);
        if (!item?.node) {
            continue;
        }
        if (rects.length === 0) {
            continue;
        }
        const absoluteRects = [];
        for (const rect of rects) {
            absoluteRects.push({
                left: rect.left + frameLeft,
                top: rect.top + frameTop,
                width: rect.width,
                height: rect.height,
            });
        }
        const target = builder(item.node, absoluteRects, viewportPayload);
        if (target) {
            targets.push(target);
        }
    }
    let surfaceRectTargetCount = 0;
    let suppliedRectTargetCount = 0;
    let lookupPayloadTargetCount = 0;
    let suppliedSuspiciousRectCount = 0;
    let droppedSuspiciousRectCount = 0;
    const messageTargets = [];
    for (const target of targets) {
        if (target?.rectSource === 'surface-text') {
            surfaceRectTargetCount += 1;
        } else if (target?.rectSource === 'supplied') {
            suppliedRectTargetCount += 1;
        }
        if (target?.lookupPayload) {
            lookupPayloadTargetCount += 1;
        }
        if (Number.isFinite(target?.suppliedSuspiciousCount)) {
            suppliedSuspiciousRectCount += target.suppliedSuspiciousCount;
        }
        if (Number.isFinite(target?.droppedSuspiciousRectCount)) {
            droppedSuspiciousRectCount += target.droppedSuspiciousRectCount;
        }
        if (target?.elementId && Array.isArray(target?.rects) && target.rects.length > 0) {
            const messageTarget = {
                elementId: target.elementId,
                rects: target.rects,
            };
            if (target.lookupPayload) {
                messageTarget.lookupPayload = target.lookupPayload;
            }
            messageTargets.push(messageTarget);
        }
    }
    if (targets.length === 0) {
        manabiTimelineMeasure('nativeLookup.targets.post', startedAt, {
            reason,
            builder: true,
            skippedEmptyPost: true,
            visibleSegmentCount: visibleSegmentsResult?.visibleSegments?.length ?? 0,
            targetCount: 0,
            frameLeft,
            frameTop,
            viewportWidth,
            viewportHeight,
        }, 100);
        return 0;
    }
    messageHandlers?.nativeLookupHitTargetsUpdated?.postMessage?.({
        targets: messageTargets,
        reason,
        nativeLookupFrameKey,
        isExplicitReset: false,
        visualViewportScale,
        viewportWidth,
        viewportHeight,
        viewportLeft,
        viewportTop,
    });
    manabiTimelineMeasure('nativeLookup.targets.post', startedAt, {
        reason,
        builder: true,
        visibleSegmentCount: visibleSegmentsResult?.visibleSegments?.length ?? 0,
        targetCount: targets.length,
        lookupPayloadCount: lookupPayloadTargetCount,
        frameLeft,
        frameTop,
        frameWidth: visibleSegmentsResult?.frameWidth ?? null,
        frameHeight: visibleSegmentsResult?.frameHeight ?? null,
        containerLeft: visibleSegmentsResult?.containerLeft ?? null,
        containerTop: visibleSegmentsResult?.containerTop ?? null,
        viewportWidth,
        viewportHeight,
        viewportLeft,
        viewportTop,
        segmentSource: visibleSegmentsResult?.segmentCandidateSource ?? null,
        hasExpectedPaginatorContainer: visibleSegmentsResult?.hasExpectedPaginatorContainer === true,
        firstVisibleSegmentID: visibleSegmentsResult?.visibleSegments?.[0]?.node?.id ?? null,
        firstTargetID: targets[0]?.elementId ?? null,
        firstTargetRectSource: targets[0]?.rectSource ?? null,
        surfaceRectTargetCount,
        suppliedRectTargetCount,
        suppliedSuspiciousRectCount,
        droppedSuspiciousRectCount,
        firstRectLeft: targets[0]?.rects?.[0]?.left ?? null,
        firstRectTop: targets[0]?.rects?.[0]?.top ?? null,
    }, 100);
    return targets.length;
};

const postNativeLookupPageTurnDisplayReady = (reason = 'unspecified') => {
    manabiTimelineMark('nativeLookup.pageTurnDisplayReady', { reason, force: true });
    window.webkit?.messageHandlers?.nativeLookupHitTargetsUpdated?.postMessage?.({
        targets: [],
        reason: 'nativeLookup.pageTurnDisplayReady',
        sourceReason: reason,
        isExplicitReset: false,
        visualViewportScale: Number.isFinite(window.visualViewport?.scale) ? window.visualViewport.scale : 1,
        viewportWidth: window.visualViewport?.width ?? window.innerWidth ?? document.documentElement?.clientWidth ?? null,
        viewportHeight: window.visualViewport?.height ?? window.innerHeight ?? document.documentElement?.clientHeight ?? null,
        viewportLeft: 0,
        viewportTop: 0,
    });
};

const visibleTrackingSignatureForResult = (doc, visibleSegmentsResult, extraParts = []) => {
    const visibleSegments = visibleSegmentsResult?.visibleSegments ?? [];
    const progress = doc?.manabi_articleReadingProgress || {};
    const isEbookDoc = isEbookContentDocument(doc);
    const trackingEnabledForSignature = doc?.body?.dataset?.mnbTrackingEnabled === 'true'
        || (isEbookDoc && doc?.manabi_trackedWordsInitialized === true);
    return [
        visibleSegments
            .map((item) => item?.node?.id || item?.segmentIdentifier || item?.node?.getAttribute?.('id') || '')
            .join(','),
        `trackedInit=${doc?.manabi_trackedWordsInitialized === true}`,
        `ebookTrackedInit=${isEbookDoc ? doc?.manabi_ebookTrackingInitialized === true : 'n/a'}`,
        `trackingEnabled=${trackingEnabledForSignature}`,
        `tracking=${doc?.manabi_trackingModelVersion || 0}`,
        `readSeg=${Array.isArray(progress.readSegmentIdentifiers) ? progress.readSegmentIdentifiers.length : 0}`,
        `readSen=${Array.isArray(progress.sentenceIdentifiersRead) ? progress.sentenceIdentifiersRead.length : 0}`,
        `finished=${progress.articleMarkedAsFinished === true}`,
        `entry=${visibleSegmentPreparedEntrySignature(visibleSegments)}`,
        ...extraParts,
    ].join('|');
};

const hydrationItemForSegmentNode = (segmentNode, bootstrap = null) => {
    if (segmentNode?.tagName?.toLowerCase?.() !== 'm-m' || segmentNode.closest?.('.tippy-box')) {
        return null;
    }
    const metadata = segmentMetadataForNode(segmentNode, bootstrap);
    const segmentIdentifier = segmentIdentifierForNode(segmentNode, bootstrap, metadata);
    if (!segmentIdentifier) {
        return null;
    }
    const sentenceNode = segmentNode.closest(manabiReaderSentenceSelector);
    return prepareVisibleSegmentItem({
        node: segmentNode,
        rect: null,
        rects: [],
        segmentIdentifier,
        segmentIdentifierAliases: segmentIdentifierAliasesForNode(segmentNode, bootstrap, metadata),
        sentenceIdentifier: sentenceIdentifierForNode(sentenceNode),
        segmentMetadata: metadata,
    }, bootstrap);
};

const expandedVisibleSegmentsResultForStatusHydration = (doc, visibleSegmentsResult, {
    adjacentSegmentCount = 0,
} = {}) => {
    const visibleSegments = visibleSegmentsResult?.visibleSegments ?? [];
    if (!isDocumentLike(doc) || visibleSegments.length === 0 || adjacentSegmentCount <= 0) {
        return visibleSegmentsResult;
    }
    const bootstrap = visibleSegmentsResult?.segmentMetadataBootstrap || segmentMetadataBootstrap(doc);
    prepareVisibleSegmentsResult(visibleSegmentsResult, doc);
    const orderedSegments = orderedSegmentNodesForDocument(doc);
    const indexByNode = orderedSegments.indexByNode;
    const visibleIndexes = visibleSegments
        .map((item) => indexByNode.get(item?.node))
        .filter((index) => Number.isFinite(index));
    if (visibleIndexes.length === 0) {
        return visibleSegmentsResult;
    }
    const firstIndex = Math.min(...visibleIndexes);
    const lastIndex = Math.max(...visibleIndexes);
    const windowStart = Math.max(0, firstIndex - adjacentSegmentCount);
    const windowEnd = Math.min(orderedSegments.nodes.length - 1, lastIndex + adjacentSegmentCount);
    const seenNodes = new Set();
    const expandedSegments = [];
    for (const item of visibleSegments) {
        if (!item?.node || seenNodes.has(item.node)) {
            continue;
        }
        seenNodes.add(item.node);
        expandedSegments.push(item);
    }
    let addedCount = 0;
    for (let index = windowStart; index <= windowEnd; index += 1) {
        const node = orderedSegments.nodes[index];
        if (!node || seenNodes.has(node)) {
            continue;
        }
        const item = hydrationItemForSegmentNode(node, bootstrap);
        if (!item) {
            continue;
        }
        seenNodes.add(node);
        expandedSegments.push(item);
        addedCount += 1;
    }
    if (addedCount === 0) {
        return visibleSegmentsResult;
    }
    return {
        ...visibleSegmentsResult,
        visibleSegments: expandedSegments,
        segmentMetadataBootstrap: bootstrap,
        preparedVisiblePayload: true,
        hydrationStrictVisibleSegmentCount: visibleSegments.length,
        hydrationExpandedSegmentCount: expandedSegments.length,
        hydrationAdjacentAddedSegmentCount: addedCount,
        hydrationAdjacentSegmentCount: adjacentSegmentCount,
    };
};

const hydrateVisibleTrackingStatusesForVisibleSegments = (doc, visibleSegmentsResult, reason = 'unspecified', {
    synchronous = true,
    adjacentSegmentCount = 0,
    allowPartialTrackedWords = false,
    retainHiddenEbookStatusClasses = false,
} = {}) => {
    const startedAt = performanceNowMs();
    const view = doc?.defaultView ?? null;
    const hydrator = view?.manabi_hydrateVisibleTrackingStatuses ?? null;
    if (typeof hydrator !== 'function') {
        return null;
    }
    const expandedHydrationResult = expandedVisibleSegmentsResultForStatusHydration(doc, visibleSegmentsResult, {
        adjacentSegmentCount,
    });
    const hydrationResult = expandedHydrationResult?.preparedVisiblePayload === true
        ? expandedHydrationResult
        : prepareVisibleSegmentsResult(expandedHydrationResult, doc);
    const visibleSegments = hydrationResult?.visibleSegments ?? [];
    const signature = visibleTrackingSignatureForResult(doc, hydrationResult, [
        `strict=${hydrationResult?.hydrationStrictVisibleSegmentCount ?? visibleSegments.length}`,
        `expanded=${hydrationResult?.hydrationExpandedSegmentCount ?? visibleSegments.length}`,
        `adjacent=${hydrationResult?.hydrationAdjacentSegmentCount ?? 0}`,
        `partial=${allowPartialTrackedWords === true}`,
        `retainHidden=${retainHiddenEbookStatusClasses === true}`,
    ]);
    if (doc.__manabiLastVisibleStatusHydrationRequestSignature === signature) {
        const coverage = {
            visibleSegmentCount: visibleSegments.length,
            skipped: true,
            skippedByParent: true,
            signatureLength: signature.length,
            mutatedCount: 0,
            wouldMutateCount: 0,
        };
        manabiTimelineMeasure('visibleStatusHydration.call', startedAt, {
            reason,
            visibleSegmentCount: visibleSegments.length,
            skipped: true,
            skippedByParent: true,
            signatureLength: signature.length,
        }, 0);
        return coverage;
    }
    doc.__manabiLastVisibleStatusHydrationRequestSignature = signature;
    let coverage = null;
    try {
        coverage = hydrator(visibleSegments, reason, {
            synchronous,
            allowPartialTrackedWords,
            retainHiddenEbookStatusClasses,
        }) ?? null;
    } catch (error) {
        if (doc) {
            doc.__manabiLastVisibleStatusHydrationRequestSignature = null;
        }
        return null;
    } finally {
        manabiTimelineMeasure('visibleStatusHydration.call', startedAt, {
            reason,
            visibleSegmentCount: visibleSegments.length,
            skipped: coverage?.skipped ?? null,
            signatureLength: coverage?.signatureLength ?? null,
            mutatedCount: coverage?.mutatedCount ?? null,
            wouldMutateCount: coverage?.wouldMutateCount ?? null,
            synchronous,
            scheduled: coverage?.scheduled ?? null,
            allowPartialTrackedWords,
            retainHiddenEbookStatusClasses,
            strictVisibleSegmentCount: hydrationResult?.hydrationStrictVisibleSegmentCount ?? visibleSegments.length,
            expandedSegmentCount: hydrationResult?.hydrationExpandedSegmentCount ?? visibleSegments.length,
            adjacentAddedSegmentCount: hydrationResult?.hydrationAdjacentAddedSegmentCount ?? 0,
            adjacentSegmentCount: hydrationResult?.hydrationAdjacentSegmentCount ?? 0,
        }, coverage?.skipped ? 0 : 50);
    }
    return coverage;
};

const buildVisiblePageTrackingStates = async (doc, articleReadingProgress, visibleRange = null, visibleSegmentsResult = null) => {
    const normalizedProgress = normalizeArticleReadingProgress(articleReadingProgress);
    const readSegmentIdentifiers = new Set(normalizedProgress.readSegmentIdentifiers);
    const readSentenceIdentifiers = new Set(normalizedProgress.sentenceIdentifiersRead);
    const hasAnyMarkedReadContent = readSegmentIdentifiers.size > 0
        || normalizedProgress.sentenceIdentifiersRead.length > 0;
    const resolvedVisibleSegmentsResult = visibleSegmentsResult || collectVisibleSegmentNodesFromRange(doc, visibleRange);
    const {
        visibleSegments,
        viewportWidth,
        viewportHeight,
        totalSegmentCount,
        hiddenTooltipCount,
        missingIdentifierCount,
        outOfViewportCount,
    } = resolvedVisibleSegmentsResult;
    const bootstrap = resolvedVisibleSegmentsResult?.segmentMetadataBootstrap || segmentMetadataBootstrap(doc);
    const clusterAxis = !!doc?.body?.classList?.contains?.('reader-vertical-writing') ? 'block' : 'inline';
    let recoveredTextSearchStringCount = 0;
    let skippedMissingSearchStringCount = 0;
    const dedupedSegments = new Map();
    const visibleSegmentIdentifiers = new Set(
        visibleSegments
            .map((item) => item.segmentIdentifier)
            .filter((identifier) => typeof identifier === 'string' && identifier.length > 0)
    );
    const visibleSegmentItemsByIdentifier = new Map();
    for (const item of visibleSegments) {
        if (typeof item.segmentIdentifier === 'string' && item.segmentIdentifier.length > 0) {
            visibleSegmentItemsByIdentifier.set(item.segmentIdentifier, item);
        }
    }
    const segmentMatchesReadProgress = (segmentIdentifier) => {
        const item = visibleSegmentItemsByIdentifier.get(segmentIdentifier);
        const aliases = Array.isArray(item?.segmentIdentifierAliases) && item.segmentIdentifierAliases.length > 0
            ? item.segmentIdentifierAliases
            : [segmentIdentifier];
        return aliases.some((identifier) => readSegmentIdentifiers.has(identifier));
    };
    const visibleSegmentIdentifierList = Array.from(visibleSegmentIdentifiers);
    const unreadVisibleSegmentIdentifiers = visibleSegmentIdentifierList
        .filter((segmentIdentifier) => !segmentMatchesReadProgress(segmentIdentifier));
    const readVisibleSegmentIdentifiers = visibleSegmentIdentifierList
        .filter((segmentIdentifier) => segmentMatchesReadProgress(segmentIdentifier));
    const unreadVisibleSegmentCount = unreadVisibleSegmentIdentifiers.length;
    const isRead = visibleSegmentIdentifiers.size > 0 && unreadVisibleSegmentCount === 0;
    const readSegmentIdentifierSample = Array.from(readSegmentIdentifiers).slice(0, 5);
    const visibleSegmentIdentifierSample = visibleSegmentIdentifierList.slice(0, 5);
    const visibleSegmentIdentifierAliasSample = visibleSegmentIdentifierList
        .slice(0, 3)
        .map((segmentIdentifier) => {
            const aliases = visibleSegmentItemsByIdentifier.get(segmentIdentifier)?.segmentIdentifierAliases;
            return Array.isArray(aliases) ? aliases.join('|') : segmentIdentifier;
        });
    const unreadVisibleSegmentIdentifierSample = unreadVisibleSegmentIdentifiers.slice(0, 5);
    const readVisibleSegmentIdentifierSample = readVisibleSegmentIdentifiers.slice(0, 5);
    const visibleReadSentenceIntersectionCount = Array.from(new Set(
        visibleSegments
            .map((item) => item.sentenceIdentifier)
            .filter((identifier) => typeof identifier === 'string' && identifier.length > 0)
    ))
        .filter((identifier) => readSentenceIdentifiers.has(identifier))
        .length;
    if (isRead) {
        const states = [{
            id: 'visible-screen',
            payload: {
                segments: [],
                sentenceIdentifiers: [],
            },
            isRead,
            hasAnyMarkedReadContent,
            unreadVisibleSegmentCount,
            visibleSegmentCount: visibleSegmentIdentifiers.size,
            fullLabel: 'Read',
            shortLabel: 'Read',
        }];
        return {
            states,
            diagnostics: {
                documentURL: doc.location?.href || null,
                viewportWidth,
                viewportHeight,
                clusterAxis,
                totalSegmentCount,
                visibleSegmentCount: visibleSegments.length,
                hiddenTooltipCount,
                missingIdentifierCount,
                outOfViewportCount,
                recoveredTextSearchStringCount,
                skippedMissingSearchStringCount,
                clusterCount: 1,
                stateCount: states.length,
                completedStateCount: 1,
                readSegmentCount: readSegmentIdentifiers.size,
                readSentenceCount: normalizedProgress.sentenceIdentifiersRead.length,
                visibleReadIntersectionCount: readVisibleSegmentIdentifiers.length,
                visibleReadSentenceIntersectionCount,
                visibleSegmentIdentifierSample,
                visibleSegmentIdentifierAliasSample,
                readSegmentIdentifierSample,
                unreadVisibleSegmentIdentifierSample,
                readVisibleSegmentIdentifierSample,
            },
        };
    }
    const sentencesByIdentifier = new Map();
    for (const item of visibleSegments) {
        if (!dedupedSegments.has(item.segmentIdentifier)) {
            const metadata = item.segmentMetadata || segmentMetadataForNode(item.node, bootstrap);
            let searchString = metadata?.s || metadata?.ns;
            if (typeof searchString !== 'string' || searchString.length === 0) {
                const textSearchString = item.node.textContent?.trim?.() || '';
                if (textSearchString.length === 0) {
                    skippedMissingSearchStringCount += 1;
                    continue;
                }
                searchString = textSearchString;
                recoveredTextSearchStringCount += 1;
            }
            const { sentenceHTML, sentenceJMDictIDs } = buildExampleSentenceForSegment(item.node, bootstrap, metadata);
            dedupedSegments.set(item.segmentIdentifier, {
                jmdictEntryIds: segmentEntryIDsForMetadata(metadata, 'jmdict'),
                jmnedictEntryIds: segmentEntryIDsForMetadata(metadata, 'jmnedict'),
                searchString,
                displayText: item.node.textContent?.trim?.() || searchString,
                segmentIdentifier: item.segmentIdentifier,
                exampleSentence: sentenceHTML,
                exampleSentenceJMDictIDs: sentenceJMDictIDs,
            });
        }
        if (item.sentenceIdentifier && !sentencesByIdentifier.has(item.sentenceIdentifier)) {
            const sentenceNode = item.node.closest(manabiReaderSentenceSelector);
            const allSegmentIdentifierAliasSets = Array.from(sentenceNode?.querySelectorAll?.('m-m') || [])
                .map((segmentNode) => {
                    const metadata = segmentNode === item.node
                        ? (item.segmentMetadata || null)
                        : segmentMetadataForNode(segmentNode, bootstrap);
                    return segmentIdentifierAliasesForNode(segmentNode, bootstrap, metadata);
                })
                .filter((aliases) => aliases.length > 0);
            sentencesByIdentifier.set(item.sentenceIdentifier, allSegmentIdentifierAliasSets);
        }
    }
    const sentenceIdentifiers = Array.from(sentencesByIdentifier.entries())
        .filter(([, allSegmentIdentifierAliasSets]) => allSegmentIdentifierAliasSets.length > 0
            && allSegmentIdentifierAliasSets.every((aliases) =>
                aliases.some((segmentIdentifier) =>
                    readSegmentIdentifiers.has(segmentIdentifier)
                    || visibleSegmentIdentifiers.has(segmentIdentifier))))
        .map(([sentenceIdentifier]) => sentenceIdentifier);
    const states = dedupedSegments.size > 0 ? [{
        id: 'visible-screen',
        payload: {
            segments: Array.from(dedupedSegments.values()),
            sentenceIdentifiers,
        },
        isRead,
        hasAnyMarkedReadContent,
        unreadVisibleSegmentCount,
        visibleSegmentCount: visibleSegmentIdentifiers.size,
        fullLabel: isRead ? 'Read' : 'Mark Read',
        shortLabel: isRead ? 'Read' : 'Mark Read',
    }] : [];
    return {
        states,
        diagnostics: {
            documentURL: doc.location?.href || null,
            viewportWidth,
            viewportHeight,
            clusterAxis,
            totalSegmentCount,
            visibleSegmentCount: visibleSegments.length,
            hiddenTooltipCount,
            missingIdentifierCount,
            outOfViewportCount,
            recoveredTextSearchStringCount,
            skippedMissingSearchStringCount,
            clusterCount: visibleSegments.length > 0 ? 1 : 0,
            stateCount: states.length,
            completedStateCount: states.filter((state) => state.isRead).length,
            readSegmentCount: readSegmentIdentifiers.size,
            readSentenceCount: normalizedProgress.sentenceIdentifiersRead.length,
            visibleReadIntersectionCount: readVisibleSegmentIdentifiers.length,
            visibleReadSentenceIntersectionCount,
            visibleSegmentIdentifierSample,
            visibleSegmentIdentifierAliasSample,
            readSegmentIdentifierSample,
            unreadVisibleSegmentIdentifierSample,
            readVisibleSegmentIdentifierSample,
        },
    };
};

const isZip = async (file) => {
    const arr = new Uint8Array(await file.slice(0, 4).arrayBuffer())
    return arr[0] === 0x50 && arr[1] === 0x4b && arr[2] === 0x03 && arr[3] === 0x04
}

const makeNativeSource = url => ({ kind: 'native', url })
const makeFileSource = file => ({ kind: 'file', file })

const makeNativeSourceURLQuery = sourceURL =>
    `sourceURL=${encodeURIComponent(sourceURL)}`

const beginNativeForegroundResourceTrace = ({ kind, sourceURL, subpath = null } = {}) => {
    const startedAt = performanceNowMs();
    const requestID = nextEbookLoadRequestID(kind || 'native-resource');
    globalThis.__manabiForegroundNativeResourcePendingCount =
        (globalThis.__manabiForegroundNativeResourcePendingCount ?? 0) + 1;
    manabiTimelineMark('nativeResource.foreground.start', {
        requestID,
        kind,
        subpath,
        pendingCount: globalThis.__manabiForegroundNativeResourcePendingCount,
    });
    return {
        requestID,
        kind,
        subpath,
        sourceURL,
        startedAt,
        finished: false,
    };
};

const finishNativeForegroundResourceTrace = (trace, stage = 'finish', extra = {}) => {
    if (!trace || trace.finished) return;
    trace.finished = true;
    globalThis.__manabiForegroundNativeResourcePendingCount = Math.max(
        0,
        (globalThis.__manabiForegroundNativeResourcePendingCount ?? 1) - 1
    );
    manabiTimelineMeasure('nativeResource.foreground', trace.startedAt, {
        requestID: trace.requestID,
        kind: trace.kind,
        subpath: trace.subpath,
        stage,
        pendingCount: globalThis.__manabiForegroundNativeResourcePendingCount,
        ...extra,
    }, 0);
};

const fetchNativeEntries = async (sourceURL) => {
    const trace = beginNativeForegroundResourceTrace({
        kind: 'entries',
        sourceURL,
    });
    try {
        const response = await fetch(`ebook://ebook/entries?${makeNativeSourceURLQuery(sourceURL)}`, {
            headers: {
                'X-Ebook-Source-URL': sourceURL,
            },
        })
        if (!response.ok) {
            throw new Error(`Failed to load native EPUB entries: ${response.status}`)
        }
        const json = await response.json()
        finishNativeForegroundResourceTrace(trace, 'body', {
            entryCount: Array.isArray(json?.entries) ? json.entries.length : null,
        });
        return json
    } catch (error) {
        finishNativeForegroundResourceTrace(trace, 'error', {
            error: error?.message || String(error),
        });
        throw error
    }
}

const fetchNativeEntryResponse = async (sourceURL, subpath) => {
    const trace = beginNativeForegroundResourceTrace({
        kind: 'entry',
        sourceURL,
        subpath,
    });
    try {
        const response = await fetch(`ebook://ebook/entry?subpath=${encodeURIComponent(subpath)}&${makeNativeSourceURLQuery(sourceURL)}`, {
            headers: {
                'X-Ebook-Source-URL': sourceURL,
            },
        })
        if (!response.ok) {
            finishNativeForegroundResourceTrace(trace, 'http-not-ok', {
                status: response.status,
            });
            return null
        }
        response.__manabiNativeForegroundResourceTrace = trace;
        return response
    } catch (error) {
        finishNativeForegroundResourceTrace(trace, 'error', {
            error: error?.message || String(error),
        });
        throw error
    }
}

const readNativeEntryText = async (response) => {
    if (!response) return null
    try {
        const arrayBuffer = await response.arrayBuffer()
        const charset = response.headers?.get?.('content-type')?.match(/charset=([^;]+)/i)?.[1]?.trim() || 'utf-8'
        let decoder
        try {
            decoder = new TextDecoder(charset)
        } catch (_error) {
            decoder = new TextDecoder('utf-8')
        }
        const text = decoder.decode(arrayBuffer)
        return text
    } finally {
        finishNativeForegroundResourceTrace(response.__manabiNativeForegroundResourceTrace, 'body-text')
    }
}

const readNativeEntryBlob = async (response) => {
    if (!response) return null
    try {
        const arrayBuffer = await response.arrayBuffer()
        const mimeType = response.headers?.get?.('content-type') || ''
        return new Blob([arrayBuffer], mimeType ? { type: mimeType } : undefined)
    } finally {
        finishNativeForegroundResourceTrace(response.__manabiNativeForegroundResourceTrace, 'body-blob')
    }
}

const makeNativeEpubLoader = async (url) => {
    const loaderStartedAt = performanceNowMs();
    const { entries: rawEntries = [] } = await fetchNativeEntries(url)
    const entries = rawEntries.map(function(entry) {
        return {
            filename: entry.path,
            uncompressedSize: entry.size ?? 0,
        };
    })
    const sizeMap = new Map(entries.map(function(entry) { return [entry.filename, entry.uncompressedSize]; }))
    const entryNames = new Set(entries.map(function(entry) { return entry.filename; }))
    const replaceText = makeReplaceText({ allowForegroundHTML: false })
    const loadText = async (name) => {
        if (!entryNames.has(name)) {
            return null
        }
        const response = await fetchNativeEntryResponse(url, name)
        return readNativeEntryText(response)
    }
    const replaceURL = makeReplaceURL(url, loadText)
    return {
        entries,
        loadText,
        loadBlob: async (name) => {
            if (!entryNames.has(name)) {
                return null
            }
            const response = await fetchNativeEntryResponse(url, name)
            return readNativeEntryBlob(response)
        },
        getSize: name => sizeMap.get(name) ?? 0,
        replaceText,
        replaceURL,
        sourceURL: url,
    }
}

const makeZipLoader = async (file) => {
    const loaderStartedAt = performanceNowMs();
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
    const map = new Map(entries.map(function(entry) { return [entry.filename, entry]; }))
    const load = f => (name, ...args) =>
    map.has(name) ? f(map.get(name), ...args) : null
    const loadText = load(function(entry) { return entry.getData(new TextWriter()); })
    const loadBlob = load(function(entry, type) { return entry.getData(new BlobWriter(type)); })
    const getSize = name => map.get(name)?.uncompressedSize ?? 0
    const replaceText = makeReplaceText()
    return {
        entries,
        loadText,
        loadBlob,
        getSize,
        replaceText
    }
}

async function getFileEntries(entry) {
    if (entry.isFile) return entry;
    const entries = await new Promise((resolve, reject) => {
        entry.createReader().readEntries(resolve, reject);
    });
    return (await Promise.all(Array.from(entries, getFileEntries))).flat();
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

const getView = async (source) => {
    let book
    if (source?.kind === 'native' && source.url) {
        const {
            EPUB
        } = await import('./epub.js')
        const loader = await makeNativeEpubLoader(source.url)
        book = await new EPUB(loader).init()
    } else if (source?.kind === 'file' && source.file?.size) {
        const file = source.file
        if (await isZip(file)) {
            const loader = await makeZipLoader(file)
            if (isCBZ(file)) {
                throw new Error('File format not yet supported')
                //            const { makeComicBook } = await import('./comic-book.js')
                //            book = makeComicBook(loader, file)
            } else if (isFBZ(file)) {
                throw new Error('File format not yet supported')
                //            const { makeFB2 } = await import('./fb2.js')
                //            const { entries } = loader
                //            const entry = entries.find(function(entry) { return entry.filename.endsWith('.fb2'); })
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
    const view = document.createElement('foliate-view')
    view.dataset.isCache = false;
    view.style.display = 'block';
    view.style.width = '100%';
    view.style.height = '100%';
    view.style.overflow = 'hidden';
    view.style.contain = 'none';
    view.style.pointerEvents = 'auto';
    const readerStage = document.getElementById('reader-stage');
    (readerStage || document.body).append(view);
    forwardShadowErrors(view.shadowRoot);
    await view.open(book)

    // Hide scrollbars on the scrolling container inside foliate-paginator's shadow DOM
    const paginator = resolveFoliatePaginator(view);
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

// Start this fetch while the book is opening. Each section receives the resolved CSS
// as one style mutation after parsing; a child-document link would add a serial custom-
// scheme request between iframe load and columnization.
const bookContentStylesheetURL = new URL('./book-content.css', import.meta.url).href;
const bookContentStylesPromise = fetch(bookContentStylesheetURL).then(response => {
    if (!response.ok) {
        throw new Error(`Unable to load book content stylesheet (${response.status})`);
    }
    return response.text();
});

const $ = document.querySelector.bind(document)

const locales = 'en'
const percentFormat = new Intl.NumberFormat(locales, {
    style: 'percent'
})

const loadingVisualDelayMs = 200;
const navSpinnerMaximumMs = 1200;

class Reader {
    #show(btn, show = true) {
        if (show) {
            if (btn.hidden) {
                btn.hidden = false;
            }
            if (btn.style.visibility !== 'visible') {
                btn.style.visibility = 'visible';
            }
        } else {
            if (!btn.hidden) {
                btn.hidden = true;
            }
            if (btn.style.visibility !== 'hidden') {
                btn.style.visibility = 'hidden';
            }
        }
    }
    setLoadingIndicator(visible, reason = 'unspecified') {
        const body = document.body;
        if (!body) return;
        const loadingIndicator = document.getElementById('loading-indicator');
        const previousVisible = body.classList.contains('loading');
        const nextVisible = !!visible;
        if (nextVisible) {
            this.loadingPaintPending = true;
        } else if (this.loadingPaintPending) {
            const isPaintBoundary = reason === 'didDisplay';
            const isTerminalFailure = reason.includes('error')
                || reason.includes('watchdog')
                || reason.includes('timeout');
            if (!isPaintBoundary && !isTerminalFailure) {
                manabiTimelineMark('loadingIndicator.clearRetainedForPaint', {
                    reason,
                    previousVisible,
                    bodyLoading: body.classList.contains('loading'),
                    bodyLoadingVisual: body.classList.contains('loading-visual'),
                    indicatorHidden: loadingIndicator?.hasAttribute?.('hidden') ?? null,
                });
                return;
            }
            this.loadingPaintPending = false;
        }
        if (nextVisible) {
            loadingIndicator?.removeAttribute?.('hidden');
            const requiresImmediateVisual = reason === 'loadEBook.start' || reason === 'reader.open';
            if (requiresImmediateVisual) {
                clearTimeout(this.loadingVisualTimer);
                this.loadingVisualTimer = null;
                body.classList.add('loading-visual');
            } else if (!previousVisible && !this.loadingVisualTimer) {
                this.loadingVisualTimer = setTimeout(() => {
                    this.loadingVisualTimer = null;
                    if (document.body?.classList?.contains?.('loading')) {
                        document.body.classList.add('loading-visual');
                    }
                }, loadingVisualDelayMs);
            }
        }
        body.classList.toggle('loading', nextVisible);
        if (!nextVisible) {
            clearTimeout(this.loadingVisualTimer);
            this.loadingVisualTimer = null;
            body.classList.remove('loading-visual');
            loadingIndicator?.setAttribute?.('hidden', '');
        }
        if (!nextVisible) {
            this.#flushPendingNativeLookupHitTargetRefresh('loading-cleared');
            this.#flushPendingBookContentHideNavigationDueToScroll('loading-cleared');
        }
        if (previousVisible !== nextVisible) {
        }
        manabiTimelineMark('loadingIndicator.state', {
            reason,
            requestedVisible: nextVisible,
            previousVisible,
            bodyLoading: body.classList.contains('loading'),
            bodyLoadingVisual: body.classList.contains('loading-visual'),
            indicatorHidden: loadingIndicator?.hasAttribute?.('hidden') ?? null,
            timerPending: this.loadingVisualTimer != null,
        });
    }
    #tocView
    #bookForSidebarCover = null
    #sidebarCoverLoadPromise = null
    #sidebarCoverObjectURL = null
    #chevronFadeAnimationFrames = {
        l: null,
        r: null
    }
    #chevronFadeAnimationCleanup = {
        l: null,
        r: null
    }
    #chevronOpacityState = {
        l: null,
        r: null
    }
    #mainDocumentSwipeState = null;
    #pageTurnInFlight = false;
    #queuedPageTurnRun = null;
    initialDisplaySettled = false;
    initialDisplaySettledPromise = null;
    initialDisplaySettledResolve = null;
    displaySettledSequence = 0;
    displaySettledWaiters = [];
    hasLoadedLastPosition = false
    markedAsFinished = false;
    showingCompletionButtons = false;
    completionAction = null;
    completionActionBusy = false;
    lastPercentValue = null;
    articleReadingProgress = normalizeArticleReadingProgress();
    pageTrackingStates = [];
    pageTrackingBusyStateIDs = new Set();
    pageTrackingAnimateReadStateIDs = new Set();
    pageReadMarkerAwaitingPageState = false;
    optimisticReadSegmentIdentifiers = new Set();
    optimisticSentenceIdentifiersRead = new Set();
    markReadSessionID = Math.random().toString(36).slice(2, 10);
    lastPageTrackingVisibility = null;
    lastPageTrackingDiagnosticsKey = null;
    lastPageTrackingStateSignature = null;
    lastPageTrackingStateSnapshot = null;
    lastRenderedPageTrackingSignature = null;
    pageTrackingStatesGeneration = -1;
    lastBookReadingProgressKey = null;
    pageTrackingRetryHandle = null;
    pageTrackingDeferredHandle = null;
    pageTrackingDeferredFrameHandle = null;
    pageTrackingDeferredReadyCleanup = null;
    pageTrackingDeferredRequest = null;
    nativeMarkReadStateRefreshHandle = null;
    pageReadMarkerDeferredHandle = null;
    initialPaginatorSettleHandle = null;
    hasSettledInitialPaginatorLayout = false;
    hasFlashedInitialForwardSideNavChevron = false;
    sameIndexGoToDidDisplaySkips = 0;
    lastLayoutDiagnosticsKey = null;
    lastLayoutSnapshot = null;
    lastCFIPersistenceObservation = null;
    unstableCFIs = new Set();
    visiblePageCollectionGeneration = 0;
    visiblePageSegmentSnapshot = null;
    lastInvalidatedVisiblePageSegmentSnapshot = null;
    nativeLookupHitTargetRefreshHandle = null;
    nativeLookupHitTargetRefreshGeneration = 0;
    pendingNativeLookupHitTargetRefresh = null;
    lookupNavigationPageTurnActive = false;
    appliedBookContentHideNavigationDueToScroll = null;
    pendingBookContentHideNavigationDueToScroll = null;
    annotations = new Map()
    annotationsByValue = new Map()
    openSideBar() {
        $('#dimming-overlay').removeAttribute('hidden')
        $('#side-bar').removeAttribute('hidden')
        $('#dimming-overlay').classList.add('show')
        $('#side-bar').classList.add('show')
        void this.#ensureSidebarCoverLoaded()
        if (this.#tocView?.setCurrentHref && this.view?.renderer?.tocItem?.href) {
            this.#tocView.setCurrentHref(this.view.renderer.tocItem.href)
        }
    }
    #ensureSidebarCoverLoaded() {
        if (this.#sidebarCoverLoadPromise) return this.#sidebarCoverLoadPromise
        const coverElement = $('#side-bar-cover')
        if (!coverElement) return Promise.resolve()
        if (coverElement?.getAttribute?.('src')) return Promise.resolve()
        const book = this.#bookForSidebarCover
        if (typeof book?.getCover !== 'function') return Promise.resolve()
        this.#sidebarCoverLoadPromise = Promise.resolve(book.getCover())
            .then(blob => {
                if (!blob) return
                if (this.#sidebarCoverObjectURL) {
                    URL.revokeObjectURL(this.#sidebarCoverObjectURL)
                }
                this.#sidebarCoverObjectURL = URL.createObjectURL(blob)
                coverElement.src = this.#sidebarCoverObjectURL
            })
            .catch(error => {
})
        return this.#sidebarCoverLoadPromise
    }
    closeSideBar() {
        $('#dimming-overlay').classList.remove('show')
        $('#side-bar').classList.remove('show')
        setTimeout(() => {
            if (!$('#side-bar').classList.contains('show')) {
                $('#dimming-overlay').setAttribute('hidden', '')
                $('#side-bar').setAttribute('hidden', '')
            }
        }, 360)
    }
    toggleTableOfContents() {
        if ($('#side-bar').classList.contains('show')) {
            this.closeSideBar()
        } else {
            this.openSideBar()
        }
    }
    async _goToDescriptor(descriptor) {
        if (!descriptor || !this.view) return;
        if (
            typeof descriptor.sectionIndex === 'number'
            && typeof descriptor.localSectionIndex === 'number'
            && typeof descriptor.rendererTotal === 'number'
            && descriptor.rendererTotal > 1
            && this.view?.renderer?.goTo
        ) {
            const clampedLocalSectionIndex = Math.max(
                0,
                Math.min(descriptor.rendererTotal - 1, Math.round(descriptor.localSectionIndex))
            );
            const fractionInSection = clampedLocalSectionIndex / (descriptor.rendererTotal - 1);
            await runWithNavigationIntent({
                source: 'goToDescriptor',
                target: 'renderer.goTo',
                sectionIndex: descriptor.sectionIndex,
                localSectionIndex: descriptor.localSectionIndex,
                rendererTotal: descriptor.rendererTotal,
                fractionInSection,
                pageItemKey: descriptor.pageItemKey ?? null,
            }, () => this.view.renderer.goTo({
                index: Math.max(0, Math.round(descriptor.sectionIndex)),
                anchor: fractionInSection,
            })).catch((error) => console.error(error));
            return;
        }
        if (typeof descriptor.cfi === 'string' && descriptor.cfi) {
            await runWithNavigationIntent({
                source: 'goToDescriptor',
                target: 'view.goTo',
                cfiLength: descriptor.cfi.length,
                pageItemKey: descriptor.pageItemKey ?? null,
            }, () => this.view.goTo(descriptor.cfi)).catch((error) => console.error(error));
            return;
        }
        if (typeof descriptor.fraction === 'number' && Number.isFinite(descriptor.fraction)) {
            await runWithNavigationIntent({
                source: 'goToDescriptor',
                target: 'view.goToFraction',
                fraction: descriptor.fraction,
                pageItemKey: descriptor.pageItemKey ?? null,
            }, () => this.view.goToFraction(descriptor.fraction));
        }
    }
    async goToHref(href, source = 'unknown') {
        if (!this.view || typeof href !== 'string' || !href) {
            return false;
        }
        this.navHUD?.requestExplicitRelocateHistoryMutation?.('goToHref');
        await runWithNavigationIntent({
            source: 'goToHref',
            target: 'view.goTo',
            href,
            requestSource: source,
        }, () => this.view.goTo(href));
        return true;
    }
    async goToPercent(percent, source = 'unknown') {
        if (!this.view) {
            return false;
        }
        this.navHUD?.requestExplicitRelocateHistoryMutation?.('goToPercent');
        const numericPercent = Number(percent);
        const clampedPercent = Math.max(0, Math.min(100, numericPercent));
        if (!Number.isFinite(clampedPercent)) {
            return false;
        }
        const fraction = clampedPercent / 100;
        await runWithNavigationIntent({
            source: 'goToPercent',
            target: 'view.goToFraction',
            percent: clampedPercent,
            fraction,
            requestSource: source,
        }, () => this.view.goToFraction(fraction));
        return true;
    }
    async goToLocationNumber(locationNumber, source = 'unknown') {
        if (!this.view) {
            return false;
        }
        this.navHUD?.requestExplicitRelocateHistoryMutation?.('goToLocation');
        const numericLocationNumber = Number(locationNumber);
        const locationTotalHint = this.navHUD?.getLocationTotalHint?.()
            ?? this.navHUD?.currentLocationDescriptor?.locationTotalHint
            ?? this.navHUD?.lastPrimaryLabelDiagnostics?.locationTotal
            ?? null;
        if (!Number.isFinite(numericLocationNumber)) {
            return false;
        }
        const maxLocationNumber = typeof locationTotalHint === 'number' && locationTotalHint > 0
            ? Math.max(1, Math.round(locationTotalHint))
            : Math.max(1, Math.round(numericLocationNumber));
        const clampedLocationNumber = Math.max(1, Math.min(maxLocationNumber, Math.round(numericLocationNumber)));
        const fraction = maxLocationNumber > 1
            ? (clampedLocationNumber - 1) / (maxLocationNumber - 1)
            : 0;
        await runWithNavigationIntent({
            source: 'goToLocationNumber',
            target: 'view.goToFraction',
            locationNumber: clampedLocationNumber,
            locationTotal: maxLocationNumber,
            fraction,
            requestSource: source,
        }, () => this.view.goToFraction(fraction));
        return true;
    }
    async goToPageNumber(pageNumber, source = 'unknown') {
        return await this.goToLocationNumber(pageNumber, source);
    }
    async buildGoToSheetSnapshot() {
        const chapters = buildGoToSnapshotChapters(this.view?.book);
        const linearSectionEntries = buildLinearSectionEntries(this.view?.book);
        const linearSectionStartPercentByHref = buildLinearSectionStartPercentByHref(this.view?.book);
        const currentLocationDescriptor = this.navHUD?.getCurrentLocationDescriptor?.() ?? null;
        const currentFraction = getAuthoritativeReaderFraction({
            navHUD: this.navHUD,
            detail: this.navHUD?.lastRelocateDetail ?? currentLocationDescriptor ?? null,
            fallbackFraction: typeof currentLocationDescriptor?.fraction === 'number'
                ? currentLocationDescriptor.fraction
                : (typeof this.navHUD?._fractionForPercent?.(this.navHUD?.lastRelocateDetail ?? null) === 'number'
                    ? this.navHUD._fractionForPercent(this.navHUD.lastRelocateDetail)
                    : null),
        });
        const currentPercent = currentFraction != null
            ? safeRound(currentFraction * 100, 1)
            : null;
        for (const entry of chapters) {
            const href = entry.href;
            let percent = null;
            let percentSource = null;
            const normalizedHref = normalizeSpineHref(href);
            const sectionStartPercent = normalizedHref != null
                ? (linearSectionStartPercentByHref.get(normalizedHref) ?? null)
                : null;
            if (typeof sectionStartPercent === 'number') {
                percent = sectionStartPercent;
                percentSource = 'linear-section-start';
            }
            entry.percent = percent;
            entry.percentSource = percentSource;
        }
        const relocateSectionIndex = typeof this.navHUD?.lastRelocateDetail?.sectionIndex === 'number'
            ? this.navHUD.lastRelocateDetail.sectionIndex
            : (typeof this.navHUD?.lastRelocateDetail?.index === 'number'
                ? this.navHUD.lastRelocateDetail.index
                : null);
        const rendererCurrentIndex = (() => {
            try {
                const currentIndex = this.view?.renderer?.currentIndex;
                if (typeof currentIndex === 'number') return currentIndex;
                return getPrimaryRendererContentIndex(this.view?.renderer);
            } catch (_) {
                return null;
            }
        })();
        const resolvedSectionIndex = this.navHUD?._resolveSectionIndex?.(this.navHUD?.lastRelocateDetail ?? {}) ?? {
            index: null,
            source: 'nav-hud-unavailable',
        };
        const currentSectionIndex = typeof resolvedSectionIndex?.index === 'number'
            ? resolvedSectionIndex.index
            : null;
        const currentSection = currentSectionIndex != null
            ? this.view?.book?.sections?.[currentSectionIndex] ?? null
            : null;
        const currentSectionHref = typeof currentSection?.id === 'string'
            ? currentSection.id
            : null;
        const normalizedCurrentSectionHref = normalizeSpineHref(currentSectionHref);
        const currentSectionEntry = normalizedCurrentSectionHref
            ? linearSectionEntries.find(function(entry) { return normalizeSpineHref(entry.href) === normalizedCurrentSectionHref; }) ?? null
            : null;
        const currentChapter = currentSectionEntry
            ? null
            : (this.view?.renderer?.tocItem ?? this.view?.lastLocation?.tocItem ?? null);
        const currentChapterHref = typeof currentSectionEntry?.href === 'string'
            ? currentSectionEntry.href
            : (currentSectionHref ?? (typeof currentChapter?.href === 'string' ? currentChapter.href : null));
        const normalizedCurrentChapterHref = normalizeSpineHref(currentChapterHref);
        const currentChapterEntry = normalizedCurrentChapterHref
            ? chapters.find(function(entry) { return normalizeSpineHref(entry.href) === normalizedCurrentChapterHref; })
            : null;
        const currentChapterPercent = typeof currentChapterEntry?.percent === 'number'
            ? currentChapterEntry.percent
            : null;
        const currentChapterIndex = currentChapterEntry
            ? chapters.findIndex(function(entry) { return normalizeSpineHref(entry.href) === normalizeSpineHref(currentChapterEntry.href); })
            : -1;
        const nextChapterPercent = currentChapterIndex >= 0
            ? (chapters.slice(currentChapterIndex + 1).find(function(entry) { return typeof entry.percent === 'number'; })?.percent ?? 100)
            : null;
        const currentChapterPercentSource = typeof currentChapterEntry?.percentSource === 'string'
            ? currentChapterEntry.percentSource
            : null;
        const canJumpBack = !!this.navHUD?._isRelocateButtonVisible?.('back');
        const canJumpForward = !!this.navHUD?._isRelocateButtonVisible?.('forward');
        const backLabel = this.navHUD?.labelForDescriptor?.(this.navHUD?._descriptorForRelocateLabel?.('back'))
            || '';
        const forwardLabel = this.navHUD?.labelForDescriptor?.(this.navHUD?._descriptorForRelocateLabel?.('forward'))
            || '';
        const snapshot = {
            isRTL: !!this.isRTL,
            currentChapterHref,
            currentChapterTitle: typeof currentSectionEntry?.title === 'string'
                ? currentSectionEntry.title
                : (typeof currentChapter?.label === 'string' ? currentChapter.label : null),
            currentPercent,
            canJumpBack,
            canJumpForward,
            backLabel,
            forwardLabel,
            currentSectionIndex,
            currentSectionIndexSource: resolvedSectionIndex?.source ?? null,
            navLastSectionIndexSeen: this.navHUD?.lastSectionIndexSeen ?? null,
            currentSectionHref,
            normalizedCurrentSectionHref,
            chapters,
        };
        return snapshot;
    }
    #bookContentReadyForNavigationChrome() {
        return !document.body?.classList?.contains?.('loading')
            && document.documentElement?.dataset?.mnbReaderRenderReady === '1';
    }
    #flushPendingBookContentHideNavigationDueToScroll(reason = 'unspecified') {
        const pending = this.pendingBookContentHideNavigationDueToScroll;
        if (!pending || !this.#bookContentReadyForNavigationChrome()) {
            return;
        }
        this.pendingBookContentHideNavigationDueToScroll = null;
        this.#applyHideNavigationDueToScrollToBookContent(pending.hidden, `${pending.reason}.flush:${reason}`);
    }
    #applyHideNavigationDueToScrollToBookContent(shouldHide, reason = 'unspecified') {
        if (MANABI_DISABLE_NAV_HIDDEN_LAYOUT_CLASSES) {
            return;
        }
        const hidden = !!shouldHide;
        const startedAt = typeof performance !== 'undefined' && typeof performance.now === 'function' ? performance.now() : Date.now();
        const mainBody = document.body;
        if (mainBody?.classList?.contains?.('nav-hidden-due-to-scroll') !== hidden) {
            mainBody?.classList?.toggle?.('nav-hidden-due-to-scroll', hidden);
        }
        if (mainBody?.dataset) {
            mainBody.dataset.mnbHideNavigationDueToScroll = hidden ? 'true' : 'false';
        }
        if (!this.#bookContentReadyForNavigationChrome()) {
            this.pendingBookContentHideNavigationDueToScroll = { hidden, reason };
            return;
        }
        const contents = this.view?.renderer?.getContents?.() || [];
        let changedCount = 0;
        for (const content of contents) {
            const body = content?.doc?.body;
            if (!body) continue;
            const isPageTurnNavigationState = reason.includes('relocate.page-turn')
                || reason.includes('navHUD.visibilityChange.relocate.page-turn');
            if (applyNavigationHiddenVisualStateToEbookBody(body, hidden, {
                reason,
                refreshPaint: !isPageTurnNavigationState,
            })) {
                changedCount += 1;
            }
        }
        this.appliedBookContentHideNavigationDueToScroll = hidden;
        const finishedAt = typeof performance !== 'undefined' && typeof performance.now === 'function' ? performance.now() : Date.now();
    }
    constructor() {
        applyStoredChromeInsets('reader.constructor');
        this.navHUD = new NavigationHUD({
            formatPercent: value => percentFormat.format(value),
            getRenderer: () => this.view?.renderer,
            onJumpRequest: descriptor => this._goToDescriptor(descriptor),
            onHideNavigationDueToScrollChange: (hidden, details = {}) => {
                this.#applyHideNavigationDueToScrollToBookContent(hidden, details?.source || 'navHUD.visibilityChange');
                if (details?.context?.bridgeSource) {
                    return;
                }
                postEbookNavigationVisibilityToNative(
                    hidden,
                    `navHUD.visibilityChange.${details?.source || 'unknown'}`,
                    {
                        previous: details?.previous ?? null,
                        context: details?.context ?? null,
                    }
                );
            },
        });
        this.scheduleGoToPageNumber = debounce((pageNumber) => {
            this.goToLocationNumber(pageNumber, 'schedule-location-number')
                .catch((error) => console.error(error));
        }, 120);
        this.scheduleGoToFraction = debounce((fraction) => {
            const clampedFraction = Math.max(0, Math.min(1, Number(fraction)));
            const currentDescriptor = this.navHUD?.getCurrentLocationDescriptor?.() ?? null;
            const targetDescriptor = this.navHUD?._descriptorFromFraction?.(clampedFraction) ?? null;
            const currentFraction = typeof currentDescriptor?.fraction === 'number'
                ? currentDescriptor.fraction
                : this.navHUD?._fractionForPercent?.(this.view?.lastLocation ?? this.navHUD?.lastRelocateDetail ?? null);
            const currentLocationCurrent = typeof currentDescriptor?.location?.current === 'number'
                ? currentDescriptor.location.current
                : null;
            const currentLocationTotal = typeof currentDescriptor?.locationTotalHint === 'number'
                ? currentDescriptor.locationTotalHint
                : null;
            const targetLocationCurrent = typeof targetDescriptor?.location?.current === 'number'
                ? targetDescriptor.location.current
                : null;
            const targetLocationTotal = typeof targetDescriptor?.locationTotalHint === 'number'
                ? targetDescriptor.locationTotalHint
                : null;
            const roundedCurrentPercent = typeof currentFraction === 'number' && Number.isFinite(currentFraction)
                ? Math.round(currentFraction * 100)
                : null;
            const roundedTargetPercent = Number.isFinite(clampedFraction)
                ? Math.round(clampedFraction * 100)
                : null;
            if (!Number.isFinite(clampedFraction) || !this.view) {
                return;
            }
            if (typeof currentFraction === 'number' && Number.isFinite(currentFraction) && Math.abs(currentFraction - clampedFraction) < 0.0005) {
                return;
            }
            if (currentLocationCurrent != null
                && targetLocationCurrent != null
                && currentLocationCurrent === targetLocationCurrent
                && currentLocationTotal != null
                && targetLocationTotal != null
                && currentLocationTotal === targetLocationTotal) {
                return;
            }
            if (roundedCurrentPercent != null && roundedTargetPercent != null && roundedCurrentPercent === roundedTargetPercent) {
                return;
            }
            runWithNavigationIntent({
                source: 'live-schedule',
                target: 'view.goToFraction',
                fraction: clampedFraction,
            }, () => this.view.goToFraction(clampedFraction))
                .then(() => {
                })
                .catch((error) => {
                    console.error(error);
                });
        }, 250);
        document.getElementById('nav-primary-text')?.addEventListener('click', (event) => {
            const wasHidden = !!this.navHUD?.hideNavigationDueToScroll;
            event.preventDefault?.();
            event.stopPropagation?.();
            event.stopImmediatePropagation?.();
            if (wasHidden) {
                ignoreNextIncomingRevealNavigation('nav-primary-text.click');
                postEbookNavigationVisibilityToNative(true, 'nav-primary-text.click.preserve-hidden', {
                    control: 'nav-primary-text',
                    target: event.target?.id || event.target?.tagName || null,
                });
            } else {
                ignoreNextIncomingHideNavigation('nav-primary-text.click');
                postEbookNavigationVisibilityToNative(false, 'nav-primary-text.click.preserve-visible', {
                    control: 'nav-primary-text',
                    target: event.target?.id || event.target?.tagName || null,
                });
            }
            postOpenReaderGoToSheetRequest('nav-primary-text', 'nav-primary-text', {
                preserveHiddenNavigation: wasHidden,
                preserveVisibleNavigation: !wasHidden,
            });
        });
        document.getElementById('nav-hidden-primary-text')?.addEventListener('click', (event) => {
            const wasHidden = !!this.navHUD?.hideNavigationDueToScroll;
            event.preventDefault?.();
            event.stopPropagation?.();
            event.stopImmediatePropagation?.();
            if (wasHidden) {
                ignoreNextIncomingRevealNavigation('nav-hidden-primary-text.click');
                postEbookNavigationVisibilityToNative(true, 'nav-hidden-primary-text.click.preserve-hidden', {
                    control: 'nav-hidden-primary-text',
                    target: event.target?.id || event.target?.tagName || null,
                });
            } else {
                ignoreNextIncomingHideNavigation('nav-hidden-primary-text.click');
                postEbookNavigationVisibilityToNative(false, 'nav-hidden-primary-text.click.preserve-visible', {
                    control: 'nav-hidden-primary-text',
                    target: event.target?.id || event.target?.tagName || null,
                });
            }
            postOpenReaderGoToSheetRequest('nav-hidden-primary-text', 'nav-hidden-primary-text', {
                preserveHiddenNavigation: wasHidden,
                preserveVisibleNavigation: !wasHidden,
            });
        });
        document.getElementById('nav-title-location-label')?.addEventListener('click', (event) => {
            const wasHidden = !!this.navHUD?.hideNavigationDueToScroll;
            event.preventDefault?.();
            event.stopPropagation?.();
            event.stopImmediatePropagation?.();
            if (wasHidden) {
                ignoreNextIncomingRevealNavigation('nav-title-location-label.click');
                postEbookNavigationVisibilityToNative(true, 'nav-title-location-label.click.preserve-hidden', {
                    control: 'nav-title-location-label',
                    target: event.target?.id || event.target?.tagName || null,
                });
            } else {
                ignoreNextIncomingHideNavigation('nav-title-location-label.click');
                postEbookNavigationVisibilityToNative(false, 'nav-title-location-label.click.preserve-visible', {
                    control: 'nav-title-location-label',
                    target: event.target?.id || event.target?.tagName || null,
                });
            }
            postOpenReaderGoToSheetRequest('nav-title-location-label', 'nav-title-location-label', {
                preserveHiddenNavigation: wasHidden,
                preserveVisibleNavigation: !wasHidden,
            });
        });
        document.getElementById('nav-bar')?.addEventListener('click', (event) => {
            const target = event.target;
            const excludedTarget = target?.closest?.('button, a, input, textarea, select, [role="button"], [contenteditable="true"], #progress-wrapper, .nav-section-progress') || null;
            const wasHidden = !!this.navHUD?.hideNavigationDueToScroll;
            const shouldHide = !wasHidden;
            const pendingContentBlankEcho = globalThis.__manabiPendingContentDocumentBlankNavigationEcho || null;
            if (pendingContentBlankEcho) {
                globalThis.__manabiPendingContentDocumentBlankNavigationEcho = null;
                const point = manabiEventScreenPoint(event);
                const dx = (point?.x ?? pendingContentBlankEcho.x) - pendingContentBlankEcho.x;
                const dy = (point?.y ?? pendingContentBlankEcho.y) - pendingContentBlankEcho.y;
                const isSyntheticTouchClick = event.sourceCapabilities?.firesTouchEvents === true
                    || (point && (dx * dx + dy * dy) <= (manabiSyntheticTouchMouseDistanceThreshold * manabiSyntheticTouchMouseDistanceThreshold));
                if (isSyntheticTouchClick) {
                    return;
                }
            }
            if (excludedTarget) {
                return;
            }
            event.preventDefault?.();
            event.stopPropagation?.();
            event.stopImmediatePropagation?.();
            postEbookNavigationVisibilityToNative(
                shouldHide,
                'toolbar.blankTap',
                {
                    control: 'nav-bar-background',
                    jsWasHidden: wasHidden,
                    jsProposedShouldHide: shouldHide,
                }
            );
        });
        $('#side-bar-close-button').addEventListener('click', () => {
            this.closeSideBar()
        })
        $('#dimming-overlay').addEventListener('click', () => this.closeSideBar())
        const pageTrackingButtonSelector = 'button[data-page-tracking-id], button[data-completion-action]';
        const pageTrackingButtonAcceptsEvent = (event, button) => {
            if (!(button instanceof HTMLElement)) {
                return false;
            }
            if (button.dataset?.completionAction) {
                return true;
            }
            const label = button.querySelector?.('.mnb-tracking-button-label') || null;
            const labelStyle = label instanceof Element ? getComputedStyle(label) : null;
            const labelVisible = label instanceof HTMLElement
                && label.offsetWidth > 1
                && Number(labelStyle?.opacity ?? 0) > 0.01;
            if (labelVisible) {
                return true;
            }
            const circle = button.querySelector?.('.mnb-tracking-button-status') || button;
            const accepted = isEventInsideElementCircle(event, circle);
            if (!accepted) {
            }
            return accepted;
        };
        const absorbPageTrackingButtonEvent = (event) => {
            const button = event.target?.closest?.(pageTrackingButtonSelector);
            if (!button) {
                return false;
            }
            if (!pageTrackingButtonAcceptsEvent(event, button)) {
                event.preventDefault?.();
                event.stopPropagation?.();
                event.stopImmediatePropagation?.();
                return true;
            }
            const wasHidden = !!this.navHUD?.hideNavigationDueToScroll;
            if (wasHidden) {
                globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay = true;
                ignoreNextIncomingRevealNavigation(`page-tracking-button.${event.type}`);
                postEbookNavigationVisibilityToNative(true, `page-tracking-button.${event.type}.preserve-hidden`, {
                    stateID: button.dataset?.pageTrackingId ?? null,
                    completionAction: button.dataset?.completionAction ?? null,
                });
            }
            event.stopPropagation?.();
            event.stopImmediatePropagation?.();
            return true;
        };
        const revealNavigationFromPageTracking = (event, source) => {
            if (event.target?.closest?.(pageTrackingButtonSelector)) {
                return false;
            }
            if (!this.navHUD?.hideNavigationDueToScroll) {
                return false;
            }
            event.preventDefault?.();
            event.stopPropagation?.();
            setNativeHideNavigationState(false, source);
            return true;
        };
        const pageTrackingButtons = document.getElementById('page-tracking-buttons');
        pageTrackingButtons?.addEventListener('touchstart', (event) => {
            if (absorbPageTrackingButtonEvent(event)) {
                return;
            }
            revealNavigationFromPageTracking(event, 'page-tracking-buttons.touchstart.reveal');
        }, { capture: true, passive: false });
        pageTrackingButtons?.addEventListener('pointerdown', (event) => {
            if (absorbPageTrackingButtonEvent(event)) {
                return;
            }
            revealNavigationFromPageTracking(event, 'page-tracking-buttons.pointerdown.reveal');
        }, { capture: true });
        pageTrackingButtons?.addEventListener('click', (event) => {
            const button = event.target?.closest?.(pageTrackingButtonSelector);
            if (!button) {
                return;
            }
            event.preventDefault?.();
            event.stopPropagation?.();
            event.stopImmediatePropagation?.();
            if (!pageTrackingButtonAcceptsEvent(event, button)) {
                return;
            }
            const wasHidden = !!this.navHUD?.hideNavigationDueToScroll;
            const completionAction = button.dataset?.completionAction;
            const stateID = button?.dataset?.pageTrackingId;
            if (wasHidden) {
                globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay = true;
                postEbookNavigationVisibilityToNative(true, 'page-tracking-button.click.preserve-hidden', {
                    stateID: stateID ?? null,
                    completionAction: completionAction ?? null,
                });
                ignoreNextIncomingRevealNavigation('page-tracking-button.click');
            } else {
                if (!completionAction && stateID) {
                    globalThis.__manabiApplyIgnoredHideNavigationOnPageTrackingAdvance = true;
                }
                ignoreNextIncomingHideNavigation('page-tracking-button.click');
            }
            if (revealNavigationFromPageTracking(event, 'page-tracking-buttons.click.reveal')) {
                return;
            }
            if (completionAction) {
                this.#handleCompletionAction(completionAction).catch((error) => console.error(error));
                return;
            }
            if (!stateID) {
                return;
            }
            this.#markPageClusterAsRead(stateID).catch((error) => console.error(error));
        });
        window.manabi_markVisiblePageAsRead = async (source = 'native') => {
            return await this.markVisiblePageAsRead(source);
        };
        window.addEventListener('resize', () => {
            this.#invalidateVisiblePageSegmentSnapshot();
        });
        window.visualViewport?.addEventListener?.('resize', () => {
            this.#invalidateVisiblePageSegmentSnapshot();
        });
        window.manabiInvalidateVisiblePageSegmentSnapshot = (reason = 'manual') => {
            this.#invalidateVisiblePageSegmentSnapshot(reason);
        };
        window.manabiRefreshVisibleTrackingStatuses = (reason = 'manual') => {
            const docs = this.#lookupContentWindows().map((view) => view.document).filter(isDocumentLike);
            for (const doc of docs) {
                const snapshot = this.visiblePageSegmentSnapshot;
                if (
                    snapshot
                    && snapshot.generation === this.visiblePageCollectionGeneration
                    && snapshot.doc === doc
                    && (snapshot.result?.visibleSegments?.length ?? 0) > 0
                ) {
                    this.#restoreVisiblePageLookupIndex(
                        doc,
                        snapshot,
                        `visible-status:${reason}:snapshot`,
                        true,
                        { includeSurfaceText: false }
                    );
                    this.#hydrateVisiblePageTracking(doc, snapshot.result, `visible-status:${reason}:snapshot`, true);
                    continue;
                }
                const visibleRange = this.#visibleRangeForDocument(doc);
                this.#visiblePageSegmentResult(doc, visibleRange, `visible-status:${reason}`, {
                    collectionMode: 'visibleStatusRefresh',
                    postIfCached: false,
                });
            }
        };
        screen.orientation?.addEventListener?.('change', () => {
            this.#invalidateVisiblePageSegmentSnapshot();
        });
    }
    #invalidateVisiblePageSegmentSnapshot(sourceReason = 'unspecified') {
        const shouldResetVisibleGeometry = shouldInvalidateVisibleSegmentGeometryForReason(sourceReason);
        if (shouldResetVisibleGeometry) {
            this.visiblePageCollectionGeneration += 1;
            if (this.visiblePageSegmentSnapshot) {
                this.lastInvalidatedVisiblePageSegmentSnapshot = this.visiblePageSegmentSnapshot;
            }
            this.visiblePageSegmentSnapshot = null;
            this.lastPageTrackingStateSignature = null;
            this.lastPageTrackingStateSnapshot = null;
            this.pageTrackingStatesGeneration = -1;
            this.hasSettledInitialPaginatorLayout = false;
            if (this.initialPaginatorSettleHandle) {
                cancelAnimationFrame(this.initialPaginatorSettleHandle);
                this.initialPaginatorSettleHandle = null;
            }
        }
        const resetReason = String(sourceReason || 'unspecified');
        const shouldResetNativeLookupTargets =
            sourceReason === 'page-turn-start'
            || sourceReason === 'lookup-navigation-page-turn-start'
            || sourceReason === 'page-turn-swipe-intent'
            || resetReason.includes('renderer.goTo')
            || resetReason.includes('renderer.relocate')
            || resetReason.startsWith('goTo')
            || resetReason.startsWith('relocate');
        const contents = this.view?.renderer?.getContents?.() || [];
        for (const content of contents) {
            const doc = content?.doc ?? content?.document ?? null;
            if (!isDocumentLike(doc)) { continue; }
            if (shouldResetVisibleGeometry) {
                doc.__manabiVisibleSegmentCollectionCache = null;
            }
            if (shouldResetNativeLookupTargets) {
                doc.__manabiLastVisibleStatusHydrationRequestSignature = null;
            }
            if (doc.defaultView) {
                doc.defaultView.__manabiVisibleSegmentCollectionGeneration = this.visiblePageCollectionGeneration;
            }
        }
        if (shouldResetNativeLookupTargets) {
            window.webkit?.messageHandlers?.nativeLookupHitTargetsUpdated?.postMessage?.({
                targets: [],
                reason: 'visible-page-segment-snapshot.invalidated',
                sourceReason,
                isExplicitReset: true,
                visualViewportScale: Number.isFinite(window.visualViewport?.scale) ? window.visualViewport.scale : 1,
                viewportWidth: window.visualViewport?.width ?? window.innerWidth ?? document.documentElement?.clientWidth ?? null,
                viewportHeight: window.visualViewport?.height ?? window.innerHeight ?? document.documentElement?.clientHeight ?? null,
                viewportLeft: 0,
                viewportTop: 0,
            });
        }
        if (this.pageTrackingRetryHandle) {
            cancelAnimationFrame(this.pageTrackingRetryHandle);
            this.pageTrackingRetryHandle = null;
        }
        if (this.nativeLookupHitTargetRefreshHandle) {
            cancelAnimationFrame(this.nativeLookupHitTargetRefreshHandle);
            this.nativeLookupHitTargetRefreshHandle = null;
        }
        this.nativeLookupHitTargetRefreshGeneration += 1;
        if (!shouldResetNativeLookupTargets && this.hasLoadedLastPosition === true) {
            this.#scheduleNativeLookupHitTargetRefreshSettle(`invalidation:${sourceReason}`);
        } else if (shouldResetNativeLookupTargets && globalThis.__manabiTimelineTraceAll === true) {
        }
    }
    async #syncPageTrackingButtons(reason = 'unspecified', explicitDoc = null, retryCount = 0) {
        const syncStartedAt = performance.now();
        const isRestorePending =
            reason === 'document-load'
            && globalThis.reader
            && globalThis.reader.hasLoadedLastPosition !== true;
        if (isRestorePending) {
            const diagnosticsKey = `restore-pending:${reason}`;
            if (this.lastPageTrackingDiagnosticsKey !== diagnosticsKey) {
                this.lastPageTrackingDiagnosticsKey = diagnosticsKey;
            }
            this.#queuePageTrackingRetry(reason, explicitDoc, retryCount);
            return;
        }
        const contents = this.view?.renderer?.getContents?.() || [];
        const doc = isDocumentLike(explicitDoc) ? explicitDoc : contents[0]?.doc;
        if (!isDocumentLike(doc)) {
            if (retryCount > 0) {
                const diagnosticsKey = `no-document-retry:${reason}:${contents.length}:${retryCount}`;
                if (this.lastPageTrackingDiagnosticsKey !== diagnosticsKey) {
                    this.lastPageTrackingDiagnosticsKey = diagnosticsKey;
                }
                this.#queuePageTrackingRetry(reason, explicitDoc, retryCount);
                return;
            }
            this.pageTrackingStates = [];
            this.pageTrackingStatesGeneration = -1;
            this.#renderPageTrackingButtons(reason);
            const diagnosticsKey = `no-document:${reason}:${contents.length}`;
            if (this.lastPageTrackingDiagnosticsKey !== diagnosticsKey) {
                this.lastPageTrackingDiagnosticsKey = diagnosticsKey;
            }
            this.#queuePageTrackingRetry(reason, explicitDoc, retryCount);
            return;
        }
        if (this.pageTrackingRetryHandle) {
            cancelAnimationFrame(this.pageTrackingRetryHandle);
            this.pageTrackingRetryHandle = null;
        }
        const syncGeneration = this.visiblePageCollectionGeneration;
        const visibleRangeStartedAt = performanceNowMs();
        const visibleRange = this.#visibleRangeForDocument(doc);
        const visibleRangeElapsedMs = performanceNowMs() - visibleRangeStartedAt;
        if (visibleRange?.collapsed === true && retryCount > 0) {
            this.#queuePageTrackingRetry(reason, doc, retryCount);
            return;
        }
        const visibleSegmentsStartedAt = performanceNowMs();
        const visibleSegmentsResult = this.#visiblePageSegmentResult(doc, visibleRange, `page-tracking:${reason}`, {
            includeClientRects: false,
            postLookupTargets: false,
            prepareLookupIndex: false,
        });
        const visibleSegmentsElapsedMs = performanceNowMs() - visibleSegmentsStartedAt;
        if (syncGeneration !== this.visiblePageCollectionGeneration) {
            return;
        }
        const pageTrackingSignature = visibleTrackingSignatureForResult(doc, visibleSegmentsResult, [
            `optimisticSeg=${this.optimisticReadSegmentIdentifiers.size}`,
            `optimisticSen=${this.optimisticSentenceIdentifiersRead.size}`,
            `finished=${this.markedAsFinished === true}`,
            `completion=${this.completionAction?.type ?? 'none'}`,
        ]);
        let states = null;
        let diagnostics = null;
        let buildStatesElapsedMs = 0;
        const cachedStateSnapshot =
            this.lastPageTrackingStateSignature === pageTrackingSignature
            ? this.lastPageTrackingStateSnapshot
            : null;
        if (cachedStateSnapshot?.states && cachedStateSnapshot?.diagnostics) {
            states = cachedStateSnapshot.states;
            diagnostics = cachedStateSnapshot.diagnostics;
            manabiTimelineMeasure('pageTracking.buildStates.cache', performanceNowMs(), {
                reason,
                stateCount: states.length,
                signatureLength: pageTrackingSignature.length,
            }, 0);
        } else {
            const buildStatesStartedAt = performanceNowMs();
            const builtState = await buildVisiblePageTrackingStates(doc, this.articleReadingProgress, visibleRange, visibleSegmentsResult);
            states = builtState.states;
            diagnostics = builtState.diagnostics;
            buildStatesElapsedMs = performanceNowMs() - buildStatesStartedAt;
            this.lastPageTrackingStateSignature = pageTrackingSignature;
            this.lastPageTrackingStateSnapshot = { states, diagnostics };
        }
        if (syncGeneration !== this.visiblePageCollectionGeneration) {
            return;
        }
        const visibleScreenState = states.find((state) => state.id === 'visible-screen') ?? null;
        const shouldRetryEmptyDocument =
            retryCount > 0
            && diagnostics.stateCount === 0
            && diagnostics.totalSegmentCount === 0
            && (
                !Number.isFinite(diagnostics.viewportWidth)
                || !Number.isFinite(diagnostics.viewportHeight)
                || diagnostics.viewportWidth <= 0
                || diagnostics.viewportHeight <= 0
            );
        if (shouldRetryEmptyDocument) {
            const diagnosticsKey = `empty-document:${reason}:${diagnostics.documentURL || 'nil'}`;
            if (this.lastPageTrackingDiagnosticsKey !== diagnosticsKey) {
                this.lastPageTrackingDiagnosticsKey = diagnosticsKey;
            }
            this.#queuePageTrackingRetry(reason, null, retryCount);
            return;
        }
        this.pageTrackingStates = states;
        this.pageTrackingStatesGeneration = syncGeneration;
        const renderStartedAt = performanceNowMs();
        this.#renderPageTrackingButtons(reason);
        const renderElapsedMs = performanceNowMs() - renderStartedAt;
        const syncElapsedMs = performanceNowMs() - syncStartedAt;
        requestAnimationFrame(() => {
        });
        manabiTimelineMeasure('pageTracking.sync', syncStartedAt, {
            reason,
            retryCount,
            visibleRangeElapsedMs,
            visibleSegmentsElapsedMs,
            buildStatesElapsedMs,
            renderElapsedMs,
            stateCount: diagnostics.stateCount,
            visibleSegmentCount: diagnostics.visibleSegmentCount,
            totalSegmentCount: diagnostics.totalSegmentCount,
            clusterCount: diagnostics.clusterCount,
        }, 100);
        const diagnosticsKey = JSON.stringify({
            reason,
            documentURL: diagnostics.documentURL,
            clusterAxis: diagnostics.clusterAxis,
            totalSegmentCount: diagnostics.totalSegmentCount,
            visibleSegmentCount: diagnostics.visibleSegmentCount,
            clusterCount: diagnostics.clusterCount,
            stateCount: diagnostics.stateCount,
            completedStateCount: diagnostics.completedStateCount,
            missingIdentifierCount: diagnostics.missingIdentifierCount,
            recoveredTextSearchStringCount: diagnostics.recoveredTextSearchStringCount,
            skippedMissingSearchStringCount: diagnostics.skippedMissingSearchStringCount,
        });
        if (this.lastPageTrackingDiagnosticsKey === diagnosticsKey) {
            return;
        }
        this.lastPageTrackingDiagnosticsKey = diagnosticsKey;
        const hasAnomaly =
            diagnostics.stateCount === 0
            || diagnostics.missingIdentifierCount > 0
            || diagnostics.skippedMissingSearchStringCount > 0
            || diagnostics.outOfViewportCount > 0;
        if (!hasAnomaly) {
            return;
        }
        const event = diagnostics.stateCount === 0
            ? 'ebook.pageTracking.sync.empty'
            : 'ebook.pageTracking.sync.anomaly';
    }
    applyBookReadingProgress(articleReadingProgress, reason = 'unspecified') {
        const incomingProgress = normalizeArticleReadingProgress(articleReadingProgress);
        const incomingReadSegmentCount = incomingProgress.readSegmentIdentifiers.length;
        const incomingSentenceReadCount = incomingProgress.sentenceIdentifiersRead.length;
        const incomingReadSegmentIdentifiers = new Set(incomingProgress.readSegmentIdentifiers);
        const incomingSentenceIdentifiersRead = new Set(incomingProgress.sentenceIdentifiersRead);
        let mergedOptimisticSegmentCount = 0;
        let mergedOptimisticSentenceCount = 0;
        for (const segmentIdentifier of this.optimisticReadSegmentIdentifiers) {
            if (!incomingReadSegmentIdentifiers.has(segmentIdentifier)) {
                mergedOptimisticSegmentCount += 1;
            }
            incomingReadSegmentIdentifiers.add(segmentIdentifier);
        }
        for (const sentenceIdentifier of this.optimisticSentenceIdentifiersRead) {
            if (!incomingSentenceIdentifiersRead.has(sentenceIdentifier)) {
                mergedOptimisticSentenceCount += 1;
            }
            incomingSentenceIdentifiersRead.add(sentenceIdentifier);
        }
        incomingProgress.readSegmentIdentifiers = Array.from(incomingReadSegmentIdentifiers);
        incomingProgress.sentenceIdentifiersRead = Array.from(incomingSentenceIdentifiersRead);
        if (mergedOptimisticSegmentCount > 0 || mergedOptimisticSentenceCount > 0) {
        }
        this.articleReadingProgress = incomingProgress;
        this.markedAsFinished = !!this.articleReadingProgress.articleMarkedAsFinished;
        this.lastPageTrackingStateSignature = null;
        this.lastPageTrackingStateSnapshot = null;
        for (const content of this.view?.renderer?.getContents?.() || []) {
            const doc = content?.doc ?? content?.document ?? null;
            if (isDocumentLike(doc)) {
                doc.__manabiLastVisibleStatusHydrationRequestSignature = null;
            }
        }
        this.pageTrackingBusyStateIDs.clear();
        this.completionActionBusy = false;
        const progressKey = JSON.stringify({
            articleMarkedAsFinished: this.articleReadingProgress.articleMarkedAsFinished,
            sentenceIdentifiersRead: this.articleReadingProgress.sentenceIdentifiersRead.length,
            readSegmentIdentifiers: this.articleReadingProgress.readSegmentIdentifiers.length,
            articleSentenceCount: this.articleReadingProgress.articleSentenceCount,
        });
        if (this.lastBookReadingProgressKey !== progressKey) {
            this.lastBookReadingProgressKey = progressKey;
        }
        requestAnimationFrame(() => {
        });
        if (MANABI_ENABLE_EBOOK_PAGE_TRACKING_BUTTONS) {
            this.#syncPageTrackingButtons('progress-applied', null, 2).catch((error) => console.error(error));
        } else {
            this.pageTrackingStates = [];
            this.#renderPageTrackingButtons('progress-applied.lazy');
            this.#scheduleNativeMarkReadStateRefresh('progress-applied');
        }
    }
    async #handleCompletionAction(actionType) {
        if (this.completionActionBusy) {
            return;
        }
        this.completionActionBusy = true;
        this.#renderPageTrackingButtons('completion-action-busy');
        try {
            switch (actionType) {
                case 'finish':
                    const sectionReadState = this.#currentSectionReadState();
                    window.webkit.messageHandlers.finishedReadingBook.postMessage({
                        topWindowURL: window.top.location.href,
                        allSectionsRead: sectionReadState.allSectionsRead,
                        currentPageNumber: sectionReadState.currentPageNumber,
                        totalPages: sectionReadState.totalPages,
                        pagesLeft: sectionReadState.pagesLeft,
                        segmentCount: sectionReadState.segmentCount,
                        unreadSegmentCount: sectionReadState.unreadSegmentCount,
                    });
                    break;
                case 'restart':
                    this.#clearOptimisticMarkReadState('restart');
                    window.webkit.messageHandlers.startOver.postMessage({});
                    await this.view?.renderer?.firstSection?.();
                    break;
                default:
                    break;
            }
        } finally {
            if (actionType !== 'finish') {
                this.completionActionBusy = false;
                this.#renderPageTrackingButtons('completion-action-finished');
            }
        }
    }
    #currentSectionReadState() {
        const currentPageNumber = typeof this.navHUD?.rendererPageSnapshot?.current === 'number'
            ? this.navHUD.rendererPageSnapshot.current
            : (typeof this.navHUD?.lastRelocateDetail?.pageNumber === 'number'
                ? this.navHUD.lastRelocateDetail.pageNumber
                : null);
        const totalPages = typeof this.navHUD?.rendererPageSnapshot?.total === 'number'
            ? this.navHUD.rendererPageSnapshot.total
            : (typeof this.navHUD?.lastRelocateDetail?.pageCount === 'number'
                ? this.navHUD.lastRelocateDetail.pageCount
                : null);
        const pagesLeft = typeof currentPageNumber === 'number' && typeof totalPages === 'number'
            ? Math.max(0, totalPages - currentPageNumber)
            : null;
        const contents = this.view?.renderer?.getContents?.() || [];
        const doc = contents[0]?.doc;
        if (!isDocumentLike(doc)) {
            return {
                allSectionsRead: true,
                reason: 'missing-document',
                documentURL: null,
                currentPageNumber,
                totalPages,
                pagesLeft,
                segmentCount: 0,
                readSegmentCount: 0,
                unreadSegmentCount: 0,
                optimisticReadSegmentCount: this.optimisticReadSegmentIdentifiers.size,
            };
        }
        const snapshotVisibleSegments = this.visiblePageSegmentSnapshot?.doc === doc
            ? (this.visiblePageSegmentSnapshot?.result?.visibleSegments ?? [])
            : [];
        const segmentNodes = snapshotVisibleSegments.length > 0
            ? snapshotVisibleSegments
                .map((item) => item?.node ?? null)
                .filter((segmentNode) => segmentNode?.tagName?.toLowerCase?.() === 'm-m')
            : Array.from(doc.querySelectorAll(manabiReaderSegmentSelector));
        const segmentIdentifiers = segmentNodes
            .map((segmentNode) => segmentIdentifierForNode(segmentNode))
            .filter((identifier) => typeof identifier === 'string' && identifier.length > 0);
        const segmentIdentifierAliasSets = segmentNodes
            .map((segmentNode) => ({
                aliases: segmentIdentifierAliasesForNode(segmentNode),
                sentenceIdentifier: sentenceIdentifierForNode(segmentNode.closest?.(manabiReaderSentenceSelector)),
            }))
            .filter((item) => item.aliases.length > 0);
        if (segmentIdentifiers.length === 0) {
            return {
                allSectionsRead: true,
                reason: 'empty-section',
                documentURL: doc.URL || doc.location?.href || null,
                currentPageNumber,
                totalPages,
                pagesLeft,
                segmentCount: 0,
                readSegmentCount: 0,
                unreadSegmentCount: 0,
                optimisticReadSegmentCount: this.optimisticReadSegmentIdentifiers.size,
            };
        }
        const readSegmentIdentifiers = new Set([
            ...normalizeArticleReadingProgress(this.articleReadingProgress).readSegmentIdentifiers,
            ...this.optimisticReadSegmentIdentifiers,
        ]);
        const readSentenceIdentifiers = new Set([
            ...normalizeArticleReadingProgress(this.articleReadingProgress).sentenceIdentifiersRead,
            ...this.optimisticSentenceIdentifiersRead,
        ]);
        const unreadSegmentCount = segmentIdentifierAliasSets
            .filter((item) => !(item.sentenceIdentifier && readSentenceIdentifiers.has(item.sentenceIdentifier))
                && !item.aliases.some((identifier) => readSegmentIdentifiers.has(identifier)))
            .length;
        if (unreadSegmentCount > 0) {
            const unreadSegmentIdentifiers = segmentIdentifierAliasSets
                .filter((item) => !(item.sentenceIdentifier && readSentenceIdentifiers.has(item.sentenceIdentifier))
                    && !item.aliases.some((identifier) => readSegmentIdentifiers.has(identifier)))
                .map((item) => item.aliases[0])
                .filter((identifier) => typeof identifier === 'string' && identifier.length > 0);
        }
        return {
            allSectionsRead: unreadSegmentCount === 0,
            reason: 'segments',
            documentURL: doc.URL || doc.location?.href || null,
            currentPageNumber,
            totalPages,
            pagesLeft,
            segmentCount: segmentIdentifiers.length,
            readSegmentCount: segmentIdentifiers.length - unreadSegmentCount,
            unreadSegmentCount,
            optimisticReadSegmentCount: this.optimisticReadSegmentIdentifiers.size,
            segmentSource: snapshotVisibleSegments.length > 0 ? 'visible-snapshot' : 'document-scan',
        };
    }
    buildMarkAllSectionsAsReadPayload() {
        const contents = this.view?.renderer?.getContents?.() || [];
        const doc = contents[0]?.doc;
        if (!isDocumentLike(doc)) {
            return null;
        }
        const segmentNodes = Array.from(doc.querySelectorAll(manabiReaderSegmentSelector))
            .filter((segmentNode) => !segmentNode.closest('.tippy-box'));
        const segmentsByIdentifier = new Map();
        const sentenceIdentifiers = new Set();
        let skippedMissingIdentifierCount = 0;
        let skippedMissingSearchStringCount = 0;
        for (const segmentNode of segmentNodes) {
            const segmentIdentifier = segmentIdentifierForNode(segmentNode);
            if (typeof segmentIdentifier !== 'string' || segmentIdentifier.length === 0) {
                skippedMissingIdentifierCount += 1;
                continue;
            }
            if (segmentsByIdentifier.has(segmentIdentifier)) {
                continue;
            }
            const metadata = segmentMetadataForNode(segmentNode);
            let searchString = metadata?.s || metadata?.ns;
            if (typeof searchString !== 'string' || searchString.length === 0) {
                searchString = segmentNode.textContent?.trim?.() || '';
            }
            if (searchString.length === 0) {
                skippedMissingSearchStringCount += 1;
                continue;
            }
            const sentenceNode = segmentNode.closest(manabiReaderSentenceSelector);
            const sentenceIdentifier = sentenceIdentifierForNode(sentenceNode);
            if (sentenceIdentifier) {
                sentenceIdentifiers.add(sentenceIdentifier);
            }
            const { sentenceHTML, sentenceJMDictIDs } = buildExampleSentenceForSegment(segmentNode);
            segmentsByIdentifier.set(segmentIdentifier, {
                jmdictEntryIds: segmentEntryIDsForNode(segmentNode, 'jmdict'),
                jmnedictEntryIds: segmentEntryIDsForNode(segmentNode, 'jmnedict'),
                searchString,
                displayText: segmentNode.textContent?.trim?.() || searchString,
                segmentIdentifier,
                exampleSentence: sentenceHTML,
                exampleSentenceJMDictIDs: sentenceJMDictIDs,
            });
        }
        const payloadSegments = Array.from(segmentsByIdentifier.values());
        const payloadSentenceIdentifiers = Array.from(sentenceIdentifiers);
        const payloadSegmentIdentifiers = payloadSegments
            .map((segment) => segment.segmentIdentifier)
            .filter((segmentIdentifier) => typeof segmentIdentifier === 'string' && segmentIdentifier.length > 0);
        if (payloadSegments.length === 0) {
            return null;
        }
        return {
            segments: payloadSegments,
            sentenceIdentifiers: payloadSentenceIdentifiers,
        };
    }
    applyOptimisticMarkAllSectionsAsReadPayload(payload) {
        const payloadSegments = Array.isArray(payload?.segments) ? payload.segments : [];
        const payloadSentenceIdentifiers = Array.isArray(payload?.sentenceIdentifiers) ? payload.sentenceIdentifiers : [];
        const payloadSegmentIdentifiers = payloadSegments
            .map((segment) => segment.segmentIdentifier)
            .filter((segmentIdentifier) => typeof segmentIdentifier === 'string' && segmentIdentifier.length > 0);
        for (const segmentIdentifier of payloadSegmentIdentifiers) {
            this.optimisticReadSegmentIdentifiers.add(segmentIdentifier);
        }
        for (const sentenceIdentifier of payloadSentenceIdentifiers) {
            this.optimisticSentenceIdentifiersRead.add(sentenceIdentifier);
        }
        const optimisticProgress = normalizeArticleReadingProgress(this.articleReadingProgress);
        optimisticProgress.readSegmentIdentifiers = Array.from(new Set([
            ...optimisticProgress.readSegmentIdentifiers,
            ...payloadSegmentIdentifiers,
        ]));
        optimisticProgress.sentenceIdentifiersRead = Array.from(new Set([
            ...optimisticProgress.sentenceIdentifiersRead,
            ...payloadSentenceIdentifiers,
        ]));
        this.applyBookReadingProgress(optimisticProgress, 'optimistic-mark-all-read');
        return payloadSegments.length;
    }
    async markAllSectionsAsRead() {
        const payload = this.buildMarkAllSectionsAsReadPayload();
        if (!payload) {
            return 0;
        }
        window.webkit.messageHandlers.markSectionAsRead.postMessage(payload);
        return this.applyOptimisticMarkAllSectionsAsReadPayload(payload);
    }
    async #markPageClusterAsRead(stateID) {
        const pageTrackingState = this.pageTrackingStates.find((state) => state.id === stateID);
        if (!pageTrackingState) {
            return;
        }
        if (pageTrackingState.payload.segments.length === 0) {
            return;
        }
        if (pageTrackingState.isRead) {
            return;
        }
        this.pageTrackingBusyStateIDs.add(stateID);
        this.#renderPageTrackingButtons('mark-read-busy');
        window.webkit.messageHandlers.markSectionAsRead.postMessage(pageTrackingState.payload);
        const payloadSegmentIdentifiers = pageTrackingState.payload.segments
            .map((segment) => segment.segmentIdentifier)
            .filter((segmentIdentifier) => typeof segmentIdentifier === 'string' && segmentIdentifier.length > 0);
        const payloadSentenceIdentifiers = pageTrackingState.payload.sentenceIdentifiers
            .filter((sentenceIdentifier) => typeof sentenceIdentifier === 'string' && sentenceIdentifier.length > 0);
        for (const segmentIdentifier of payloadSegmentIdentifiers) {
            this.optimisticReadSegmentIdentifiers.add(segmentIdentifier);
        }
        for (const sentenceIdentifier of payloadSentenceIdentifiers) {
            this.optimisticSentenceIdentifiersRead.add(sentenceIdentifier);
        }
        const optimisticProgress = normalizeArticleReadingProgress(this.articleReadingProgress);
        optimisticProgress.readSegmentIdentifiers = Array.from(new Set([
            ...optimisticProgress.readSegmentIdentifiers,
            ...payloadSegmentIdentifiers,
        ]));
        optimisticProgress.sentenceIdentifiersRead = Array.from(new Set([
            ...optimisticProgress.sentenceIdentifiersRead,
            ...payloadSentenceIdentifiers,
        ]));
        this.pageTrackingAnimateReadStateIDs.add(stateID);
        this.applyBookReadingProgress(optimisticProgress, 'optimistic-mark-read');
        await this.#advanceAfterMarkRead();
    }
    async markVisiblePageAsRead(source = 'native') {
        const completionAction = this.completionAction;
        if (completionAction) {
            if (this.completionActionBusy) {
                return false;
            }
            const wasHidden = !!this.navHUD?.hideNavigationDueToScroll;
            if (wasHidden) {
                globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay = true;
                postEbookNavigationVisibilityToNative(true, 'native-page-tracking-button.preserve-hidden', {
                    completionAction: completionAction.type ?? null,
                    source,
                });
                ignoreNextIncomingRevealNavigation('native-page-tracking-button');
            } else {
                ignoreNextIncomingHideNavigation('native-page-tracking-button');
            }
            await this.#handleCompletionAction(completionAction.type);
            return true;
        }
        const stateID = 'visible-screen';
        const pageTrackingState = this.pageTrackingStates.find((state) => state.id === stateID)
            ?? await this.#ensureVisiblePageTrackingState(`native-demand:${source}`);
        if (!pageTrackingState) {
            return false;
        }
        const wasHidden = !!this.navHUD?.hideNavigationDueToScroll;
        if (wasHidden) {
            globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay = true;
            postEbookNavigationVisibilityToNative(true, 'native-page-tracking-button.preserve-hidden', {
                stateID,
                source,
            });
            ignoreNextIncomingRevealNavigation('native-page-tracking-button');
        } else {
            globalThis.__manabiApplyIgnoredHideNavigationOnPageTrackingAdvance = true;
            ignoreNextIncomingHideNavigation('native-page-tracking-button');
        }
        await this.#markPageClusterAsRead(stateID);
        return true;
    }
    async #ensureVisiblePageTrackingState(reason = 'native-demand', explicitDoc = null) {
        const contents = this.view?.renderer?.getContents?.() || [];
        const doc = isDocumentLike(explicitDoc) ? explicitDoc : contents[0]?.doc;
        if (!isDocumentLike(doc)) {
            this.pageTrackingStates = [];
            this.pageTrackingStatesGeneration = -1;
            this.#renderPageTrackingButtons(`${reason}:no-doc`);
            return null;
        }
        const currentVisibleState = this.pageTrackingStates.find((state) => state.id === 'visible-screen') ?? null;
        if (currentVisibleState && this.pageTrackingStatesGeneration === this.visiblePageCollectionGeneration) {
            return currentVisibleState;
        }
        const syncGeneration = this.visiblePageCollectionGeneration;
        const visibleRange = this.#visibleRangeForDocument(doc);
        if (visibleRange?.collapsed === true) {
            return null;
        }
        const visibleSegmentsResult = this.#visiblePageSegmentResult(
            doc,
            visibleRange,
            `mark-read-state:${reason}`,
            {
                includeClientRects: false,
                postLookupTargets: false,
                prepareLookupIndex: false,
                hydrateStatuses: false,
            }
        );
        if (syncGeneration !== this.visiblePageCollectionGeneration) {
            return null;
        }
        const pageTrackingSignature = visibleTrackingSignatureForResult(doc, visibleSegmentsResult, [
            `optimisticSeg=${this.optimisticReadSegmentIdentifiers.size}`,
            `optimisticSen=${this.optimisticSentenceIdentifiersRead.size}`,
            `finished=${this.markedAsFinished === true}`,
            `completion=${this.completionAction?.type ?? 'none'}`,
        ]);
        let states = null;
        const cachedStateSnapshot =
            this.lastPageTrackingStateSignature === pageTrackingSignature
            ? this.lastPageTrackingStateSnapshot
            : null;
        if (cachedStateSnapshot?.states) {
            states = cachedStateSnapshot.states;
            manabiTimelineMeasure('pageTracking.ensureState.cache', performanceNowMs(), {
                reason,
                stateCount: states.length,
                signatureLength: pageTrackingSignature.length,
            }, 0);
        } else {
            const builtState = await buildVisiblePageTrackingStates(
                doc,
                this.articleReadingProgress,
                visibleRange,
                visibleSegmentsResult
            );
            states = builtState.states;
            this.lastPageTrackingStateSignature = pageTrackingSignature;
            this.lastPageTrackingStateSnapshot = {
                states,
                diagnostics: builtState.diagnostics,
            };
        }
        if (syncGeneration !== this.visiblePageCollectionGeneration) {
            return null;
        }
        this.pageTrackingStates = states;
        this.pageTrackingStatesGeneration = syncGeneration;
        this.#renderPageTrackingButtons(reason);
        return states.find((state) => state.id === 'visible-screen') ?? null;
    }
    #renderPageTrackingButtons(reason = 'unspecified') {
        const container = document.getElementById('page-tracking-container');
        const buttonHost = document.getElementById('page-tracking-buttons');
        const postNativeMarkReadState = (available, state = null, isBusy = false) => {
            try {
                window.webkit?.messageHandlers?.ebookNativeMarkReadState?.postMessage?.({
                    available: !!available,
                    isRead: !!state?.isRead,
                    isBusy: !!isBusy,
                    hasAnyMarkedReadContent: !!state?.hasAnyMarkedReadContent,
                    stateID: state?.id ?? null,
                    reason,
                });
            } catch (_error) {}
        };
        const pageTrackingStates = this.pageTrackingStates || [];
        const hasStates = pageTrackingStates.length > 0;
        const completionAction = this.completionAction;
        const markReadButtonsVisible = document.body?.dataset?.mnbMarkReadButtonsVisible !== 'false';
        const visibleState = pageTrackingStates.find((state) => state.id === 'visible-screen') ?? null;
        const nativeMarkReadState = completionAction
            ? {
                id: `completion-action:${completionAction.type ?? 'unknown'}`,
                isRead: false,
                hasAnyMarkedReadContent: false,
            }
            : visibleState;
        const nativeMarkReadAvailable = markReadButtonsVisible && (!!completionAction || !!nativeMarkReadState);
        const nativeMarkReadBusy = completionAction
            ? !!this.completionActionBusy
            : this.pageTrackingBusyStateIDs.has(nativeMarkReadState?.id);
        const renderSignature = JSON.stringify({
            hasContainer: container instanceof HTMLElement,
            hasButtonHost: buttonHost instanceof HTMLElement,
            visible: markReadButtonsVisible,
            completion: completionAction ? {
                type: completionAction.type ?? null,
                tone: completionAction.tone ?? null,
                label: completionAction.label ?? null,
                busy: !!this.completionActionBusy,
            } : null,
            states: pageTrackingStates.map((state) => ({
                id: state.id,
                isRead: !!state.isRead,
                hasAnyMarkedReadContent: !!state.hasAnyMarkedReadContent,
                shortLabel: state.shortLabel,
                fullLabel: state.fullLabel,
                busy: this.pageTrackingBusyStateIDs.has(state.id),
                animate: this.pageTrackingAnimateReadStateIDs.has(state.id),
            })),
            native: {
                available: !!nativeMarkReadAvailable,
                stateID: nativeMarkReadState?.id ?? null,
                isRead: !!nativeMarkReadState?.isRead,
                isBusy: !!nativeMarkReadBusy,
                hasAnyMarkedReadContent: !!nativeMarkReadState?.hasAnyMarkedReadContent,
            },
        });
        if (this.lastRenderedPageTrackingSignature === renderSignature) {
            return;
        }
        this.lastRenderedPageTrackingSignature = renderSignature;
        const clearHTMLButtons = () => {
            if (container instanceof HTMLElement) container.hidden = true;
            if (buttonHost instanceof HTMLElement) {
                buttonHost.hidden = true;
                buttonHost.innerHTML = '';
            }
            this.lastPageTrackingVisibility = false;
        };

        if (!(container instanceof HTMLElement) || !(buttonHost instanceof HTMLElement)) {
            this.#updatePageReadMarker(reason, visibleState);
            this.navHUD?.refreshAuxiliaryLayout?.();
            postNativeMarkReadState(nativeMarkReadAvailable, nativeMarkReadState, nativeMarkReadBusy);
            return;
        }

        if (!MANABI_ENABLE_EBOOK_PAGE_TRACKING_BUTTONS) {
            clearHTMLButtons();
            this.#updatePageReadMarker(reason, visibleState);
            this.navHUD?.refreshAuxiliaryLayout?.();
            postNativeMarkReadState(nativeMarkReadAvailable, nativeMarkReadState, nativeMarkReadBusy);
            return;
        }

        const shouldShowPageTracking = markReadButtonsVisible && (!!completionAction || hasStates);
        container.hidden = !shouldShowPageTracking;
        buttonHost.hidden = !shouldShowPageTracking;
        this.lastPageTrackingVisibility = shouldShowPageTracking;
        if (!shouldShowPageTracking) {
            buttonHost.innerHTML = '';
            this.#updatePageReadMarker(reason, null);
            this.navHUD?.refreshAuxiliaryLayout?.();
            postNativeMarkReadState(false, visibleState);
            return;
        }
        if (completionAction) {
            const isBusy = !!this.completionActionBusy;
            buttonHost.innerHTML = `
                <button
                    class="page-read-button mnb-tracking-button"
                    data-completion-action="${completionAction.type}"
                    data-completion-tone="${completionAction.tone}"
                    data-mnb-force-expanded="true"
                    aria-label="${completionAction.label}"
                    ${isBusy ? 'disabled' : ''}
                >
                    <span class="mnb-tracking-button-status" aria-hidden="true"></span>
                    <span class="mnb-tracking-button-label" aria-hidden="true">${completionAction.label}</span>
                    <span class="sr-only">${completionAction.label}</span>
                </button>
            `;
            this.#updatePageReadMarker(reason, null);
            this.navHUD?.syncPageTrackingButtonsNavigationDisabled?.();
            this.navHUD?.refreshAuxiliaryLayout?.();
            this.#scheduleInitialPaginatorSettle('page-tracking-render.completion-action');
            postNativeMarkReadState(true, nativeMarkReadState, isBusy);
            return;
        }
        postNativeMarkReadState(
            !!visibleState,
            visibleState,
            this.pageTrackingBusyStateIDs.has('visible-screen')
        );
        buttonHost.innerHTML = pageTrackingStates.map((state) => {
            const isBusy = this.pageTrackingBusyStateIDs.has(state.id);
            const readState = isBusy ? 'pending' : (state.isRead ? 'complete' : 'ready');
            const shouldAnimateRead = this.pageTrackingAnimateReadStateIDs.has(state.id)
                && state.id === 'visible-screen'
                && !!state.isRead
                && !isBusy;
            if (shouldAnimateRead || (this.pageTrackingAnimateReadStateIDs.has(state.id) && !!state.isRead && !isBusy)) {
                this.pageTrackingAnimateReadStateIDs.delete(state.id);
            }
            return `
                <button
                    class="page-read-button mnb-tracking-button"
                    data-page-tracking-id="${state.id}"
                    data-read-state="${readState}"
                    data-mnb-animate-read="${shouldAnimateRead ? 'true' : 'false'}"
                    data-mnb-tracking-section-read="${state.isRead ? 'true' : 'false'}"
                    data-mnb-has-any-marked-read="${state.hasAnyMarkedReadContent ? 'true' : 'false'}"
                    aria-label="${state.fullLabel}"
                    ${state.isRead || isBusy ? 'disabled' : ''}
                >
                    <span class="mnb-tracking-button-status" aria-hidden="true">
                        <span class="mnb-tracking-status-checkmark" aria-hidden="true"></span>
                    </span>
                    <span class="mnb-tracking-button-label" aria-hidden="true">${state.shortLabel}</span>
                    <span class="sr-only">${state.fullLabel}</span>
                </button>
            `;
        }).join('');
        this.#updatePageReadMarker(reason);
        this.navHUD?.syncPageTrackingButtonsNavigationDisabled?.();
        this.navHUD?.refreshAuxiliaryLayout?.();
        this.#scheduleInitialPaginatorSettle('page-tracking-render');
    }
    #pageTurnDirectionForMove(method) {
        if (method === 'goLeft') {
            return this.isRTL ? 'forward' : 'backward';
        }
        if (method === 'goRight') {
            return this.isRTL ? 'backward' : 'forward';
        }
        return null;
    }
    #applyPageTurnNavigationVisibility(method, source) {
        const direction = this.#pageTurnDirectionForMove(method);
        if (direction !== 'forward' && direction !== 'backward') {
            return;
        }
        this.#applyLogicalPageTurnNavigationVisibility(direction, source, { method });
    }
    #applyLogicalPageTurnNavigationVisibility(direction, source, details = {}) {
        if (direction !== 'forward' && direction !== 'backward') {
            return;
        }
        const shouldHide = direction === 'forward';
        try {
            recordPageTurnNavigationIntent?.(direction, source, {
                isRTL: this.isRTL,
                ...details,
            });
        } catch (_) {}
        this.navHUD?.setHideNavigationDueToScroll?.(shouldHide, source, {
            direction,
            isRTL: this.isRTL,
            ...details,
        });
        postEbookNavigationVisibilityToNative?.(shouldHide, source, {
            direction,
            isRTL: this.isRTL,
            ...details,
        });
    }
    async #runPageTurn({
        stage,
        move,
        markInputSource = null,
        clearReadChromeReason = 'page-turn-start',
        details = {},
    }) {
        if (this.#pageTurnInFlight) {
            this.#queuedPageTurnRun = {
                stage,
                move,
                markInputSource,
                clearReadChromeReason,
                details,
            };
            return { ignored: true, reason: 'pageTurnInFlightQueued' };
        }
        if (typeof move !== 'function') {
            return { ignored: true, reason: 'missingMoveHandler' };
        }

        this.#pageTurnInFlight = true;
        const startedAt = performanceNowMs();
        if (markInputSource) {
            markRestorePositionSavePageTurnInput(markInputSource);
        }
        this.#clearVisiblePageReadChrome(clearReadChromeReason);
        let result = null;
        let thrownError = null;
        try {
            result = markInputSource
                ? await runWithNavigationIntent({
                    source: markInputSource,
                    stage,
                    pageTurn: true,
                    ...details,
                }, move)
                : await move();
            return result ?? {};
        } catch (error) {
            thrownError = error;
            manabiTimelineMark('pageTurn.reader.run.error', {
                stage,
                markInputSource,
                message: error?.message || String(error),
                elapsedMs: safeRound(performanceNowMs() - startedAt, 1),
            });
            throw error;
        } finally {
            this.#pageTurnInFlight = false;
            manabiTimelineMeasure('pageTurn.run', startedAt, {
                stage,
                markInputSource,
                queued: false,
                hasQueuedPageTurn: !!this.#queuedPageTurnRun,
            }, 0);
            const queuedPageTurnRun = this.#queuedPageTurnRun;
            this.#queuedPageTurnRun = null;
            if (queuedPageTurnRun) {
                queueMicrotask(() => {
                    void this.#runPageTurn(queuedPageTurnRun).catch((error) => {
                    });
                });
            }
        }
    }
    #pageReadMarkerTransitionMode(reason = 'unspecified') {
        const value = String(reason || '');
        if (
            value === 'page-turn-start'
            || value.startsWith('relocate')
            || value.startsWith('goTo')
            || value.startsWith('did-display')
            || value.startsWith('page-tracking-visibility.relocate')
        ) {
            return 'instant';
        }
        return 'animated';
    }
    #updatePageReadMarker(reason = 'unspecified', explicitState = null, explicitDoc = null) {
        const transitionMode = this.#pageReadMarkerTransitionMode(reason);
        const state = explicitState || (this.pageTrackingStates || []).find((candidate) => candidate.id === 'visible-screen') || null;
        let isRead = !!state?.isRead && !this.completionAction;
        if (explicitState) {
            this.pageReadMarkerAwaitingPageState = false;
        } else if (this.pageReadMarkerAwaitingPageState && isRead) {
            isRead = false;
        }
        const doc = isDocumentLike(explicitDoc)
            ? explicitDoc
            : (this.view?.renderer?.getContents?.()?.[0]?.doc ?? null);
        const isVertical = !!doc?.body?.classList?.contains?.('reader-vertical-writing');
        const readerStage = document.getElementById('reader-stage');
        const preferredFoliateView = this.view?.isConnected ? this.view : null;
        const liveFoliateView =
            (preferredFoliateView && preferredFoliateView.offsetParent !== null ? preferredFoliateView : null)
            || document.querySelector('foliate-view:not([hidden])')
            || preferredFoliateView
            || null;
        if (readerStage instanceof HTMLElement) {
            readerStage.style.removeProperty('--mnb-ebook-read-marker-top-left');
            readerStage.style.removeProperty('--mnb-ebook-read-marker-top-width');
            const stageRect = readerStage.getBoundingClientRect();
            const viewRect = liveFoliateView?.getBoundingClientRect?.() || null;
            const livePaginator = resolveFoliatePaginator(liveFoliateView);
            const paginatorContainer = livePaginator?.shadowRoot?.getElementById?.('container') || null;
            const containerRect = paginatorContainer?.getBoundingClientRect?.() || null;
            const rootStyle = getComputedStyle(document.documentElement);
            const thickness = parseFloat(rootStyle.getPropertyValue('--mnb-tracking-section-border-size')) || 2;
            const sideNavWidth = parseFloat(rootStyle.getPropertyValue('--side-nav-width')) || 32;
            const containerStyle = containerRect ? getComputedStyle(paginatorContainer) : null;
            const containerTopMargin = parseFloat(containerStyle?.getPropertyValue('--_top-margin')) || 0;
            const containerBottomMargin = parseFloat(containerStyle?.getPropertyValue('--_bottom-margin')) || 0;
            const markerAnchorRect = containerRect && containerRect.width > 0 && containerRect.height > 0
                ? containerRect
                : viewRect;
            if (markerAnchorRect && markerAnchorRect.width > 0 && markerAnchorRect.height > 0 && stageRect.width > 0) {
                const markerLeft = markerAnchorRect.left - stageRect.left - thickness;
                const markerTopInset = markerAnchorRect === containerRect ? containerTopMargin : 0;
                const markerBottomInset = markerAnchorRect === containerRect ? containerBottomMargin : 0;
                const markerHeight = Math.max(0, markerAnchorRect.height - markerTopInset - markerBottomInset);
                readerStage.style.setProperty('--mnb-ebook-read-marker-side-left', `${markerLeft}px`);
                readerStage.style.setProperty('--mnb-ebook-read-marker-side-top', `${Math.max(0, markerAnchorRect.top - stageRect.top + markerTopInset)}px`);
                readerStage.style.setProperty('--mnb-ebook-read-marker-side-height', `${markerHeight}px`);
            } else if (stageRect.width > 0) {
                const markerLeft = Math.max(0, sideNavWidth - thickness);
                readerStage.style.setProperty('--mnb-ebook-read-marker-side-left', `${markerLeft}px`);
                readerStage.style.setProperty('--mnb-ebook-read-marker-side-top', '0px');
                readerStage.style.setProperty('--mnb-ebook-read-marker-side-height', `${stageRect.height}px`);
            } else {
                readerStage.style.removeProperty('--mnb-ebook-read-marker-side-left');
                readerStage.style.removeProperty('--mnb-ebook-read-marker-side-top');
                readerStage.style.removeProperty('--mnb-ebook-read-marker-side-height');
            }
        }
        document.body?.setAttribute?.('data-page-read-marker-transition', transitionMode);
        document.body?.setAttribute?.('data-page-read-marker-read', isRead ? 'true' : 'false');
        document.body?.setAttribute?.('data-page-read-marker-axis', isVertical ? 'block' : 'inline');
    }
    #clearVisiblePageReadChrome(reason = 'unspecified') {
        const isPageTurnStart = reason === 'page-turn-start' || reason === 'lookup-navigation-page-turn-start';
        if (isPageTurnStart) {
            this.#invalidateVisiblePageSegmentSnapshot(reason);
            this.pageReadMarkerAwaitingPageState = true;
        }
        document.body?.setAttribute?.('data-page-read-marker-transition', this.#pageReadMarkerTransitionMode(reason));
        document.body?.setAttribute?.('data-page-read-marker-read', 'false');
    }
    #clearOptimisticMarkReadState(_reason = 'unspecified') {
        this.optimisticReadSegmentIdentifiers.clear();
        this.optimisticSentenceIdentifiersRead.clear();
    }
    #queuePageTrackingRetry(reason, explicitDoc, retryCount) {
        if (retryCount <= 0) {
            return;
        }
        if (this.pageTrackingRetryHandle) {
            cancelAnimationFrame(this.pageTrackingRetryHandle);
        }
        this.pageTrackingRetryHandle = requestAnimationFrame(() => {
            this.pageTrackingRetryHandle = null;
            this.#syncPageTrackingButtons(reason, explicitDoc, retryCount - 1).catch((error) => console.error(error));
        });
    }
    #schedulePageTrackingSync(reason = 'unspecified', explicitDoc = null, retryCount = 0) {
        if (!MANABI_ENABLE_EBOOK_PAGE_TRACKING_BUTTONS) {
            this.#scheduleNativeMarkReadStateRefresh(reason, explicitDoc);
            return;
        }
        if (this.pageTrackingDeferredHandle) {
            cancelAnimationFrame(this.pageTrackingDeferredHandle);
            this.pageTrackingDeferredHandle = null;
        }
        if (this.pageTrackingDeferredFrameHandle) {
            cancelAnimationFrame(this.pageTrackingDeferredFrameHandle);
            this.pageTrackingDeferredFrameHandle = null;
        }
        if (this.pageTrackingDeferredReadyCleanup) {
            this.pageTrackingDeferredReadyCleanup();
            this.pageTrackingDeferredReadyCleanup = null;
        }
        const targetDoc = explicitDoc ?? document;
        const runOnStableFrame = () => {
            this.pageTrackingDeferredHandle = requestAnimationFrame(() => {
                this.pageTrackingDeferredHandle = null;
                this.pageTrackingDeferredFrameHandle = requestAnimationFrame(() => {
                    this.pageTrackingDeferredFrameHandle = null;
                    this.#syncPageTrackingButtons(reason, explicitDoc, retryCount).catch((error) => console.error(error));
                });
            });
        };
        if (targetDoc?.readyState === 'loading') {
            const onReady = () => {
                this.pageTrackingDeferredReadyCleanup = null;
                runOnStableFrame();
            };
            targetDoc.addEventListener('DOMContentLoaded', onReady, { once: true });
            this.pageTrackingDeferredReadyCleanup = () => {
                targetDoc.removeEventListener('DOMContentLoaded', onReady);
            };
            return;
        }
        runOnStableFrame();
    }
    #scheduleNativeMarkReadStateRefresh(reason = 'unspecified', explicitDoc = null) {
        if (this.nativeMarkReadStateRefreshHandle) {
            cancelAnimationFrame(this.nativeMarkReadStateRefreshHandle);
            this.nativeMarkReadStateRefreshHandle = null;
        }
        this.nativeMarkReadStateRefreshHandle = requestAnimationFrame(() => {
            this.nativeMarkReadStateRefreshHandle = requestAnimationFrame(() => {
                this.nativeMarkReadStateRefreshHandle = null;
                if (globalThis.__manabiRestoreInProgress === true || document.body?.classList?.contains?.('loading') === true) {
                    return;
                }
                this.#ensureVisiblePageTrackingState(`lazy:${reason}`, explicitDoc).catch((error) => console.error(error));
            });
        });
    }
    #visibleRangeForDocument(doc) {
        return visibleRangeForNavigationHUDDocument(this.navHUD, doc);
    }
    #collectVisiblePageSegmentGeometry(doc, visibleRange = null, reason = 'visible-page-segment-result', {
        includeClientRects = true,
        includeSegmentMetadata = true,
        viewportSampleDensity = null,
        minimumViewportSampleSegmentCount = 0,
        seedSegmentNodes = null,
        seedSegmentSource = null,
        useOrderedDocumentWindow = false,
        includeLookupSurfaceText = true,
    } = {}) {
        const result = collectVisibleSegmentNodesFromRange(doc, visibleRange, {
            includeClientRects,
            includeSegmentMetadata,
            reason,
            viewportSampleDensity,
            minimumViewportSampleSegmentCount,
            seedSegmentNodes,
            seedSegmentSource,
            useOrderedDocumentWindow,
        });
        return includeSegmentMetadata ? prepareVisibleSegmentsResult(result, doc) : result;
    }
    #prepareVisiblePageLookupIndex(doc, result, reason = 'unspecified', prepareLookupIndex = true, {
        includeSurfaceText = true,
    } = {}) {
        return prepareLookupIndex ? buildVisiblePageLookupIndex(doc, result, reason, { includeSurfaceText }) : null;
    }
    #restoreVisiblePageLookupIndex(doc, snapshot, reason = 'unspecified', prepareLookupIndex = true, {
        includeSurfaceText = true,
    } = {}) {
        if (!prepareLookupIndex || !snapshot) {
            return null;
        }
        if (snapshot.lookupIndex && visibleLookupIndexNeedsSidecarRefresh(doc, snapshot.lookupIndex)) {
            snapshot.lookupIndex = this.#prepareVisiblePageLookupIndex(doc, snapshot.result, `${reason}:sidecar-refresh`, true, {
                includeSurfaceText,
            });
        }
        if (snapshot.lookupIndex) {
            doc.manabiVisiblePageLookupIndex = snapshot.lookupIndex;
            if (doc.defaultView) {
                doc.defaultView.__manabiVisiblePageLookupIndex = snapshot.lookupIndex;
            }
            return snapshot.lookupIndex;
        }
        snapshot.lookupIndex = this.#prepareVisiblePageLookupIndex(doc, snapshot.result, reason, true, {
            includeSurfaceText,
        });
        return snapshot.lookupIndex;
    }
    #postVisiblePageLookupTargets(doc, result, reason = 'unspecified', shouldPost = true) {
        if (shouldPost) {
            return postNativeLookupHitTargetsForVisibleSegments(doc, result, reason);
        }
        return null;
    }
    #hydrateVisiblePageTracking(doc, result, reason = 'unspecified', hydrateStatuses = true, {
        synchronous = true,
        adjacentSegmentCount = 0,
        allowPartialTrackedWords = false,
        retainHiddenEbookStatusClasses = false,
    } = {}) {
        if (hydrateStatuses && (result?.visibleSegments?.length ?? 0) > 0) {
            hydrateVisibleTrackingStatusesForVisibleSegments(doc, result, reason, {
                synchronous,
                adjacentSegmentCount,
                allowPartialTrackedWords,
                retainHiddenEbookStatusClasses,
            });
        }
    }
    #renderableContentProbeResult(doc, visibleRange = null, reason = 'initial-renderable-probe') {
        // This probe only decides whether content is ready to reveal. Finishing the
        // lookup/status critical section here can synchronously apply tracking state
        // and force whole-book layout before the loading cover reaches its first
        // paint. The deferred visible-target refresh finishes that work after reveal.
        return renderableContentProbeResultForDocument(doc, visibleRange, reason);
    }
    visiblePageSegmentResult(doc, visibleRange = null, reason = 'visible-page-segment-result', options = {}) {
        return this.#visiblePageSegmentResult(doc, visibleRange, reason, options);
    }
    #visiblePageSegmentResult(doc, visibleRange = null, reason = 'visible-page-segment-result', options = {}) {
        const resolvedOptions = visiblePageSegmentCollectionOptions(options?.collectionMode, options);
        const {
            postIfCached = false,
            includeClientRects = true,
            includeSegmentMetadata = true,
            postLookupTargets = true,
            prepareLookupIndex = true,
            hydrateStatuses = true,
            hydrateStatusesSynchronously = true,
            hydrateAdjacentStatusSegmentCount = 0,
            hydrateAllowPartialTrackedWords = false,
            hydrateRetainHiddenEbookStatusClasses = false,
            viewportSampleDensity = null,
            minimumViewportSampleSegmentCount = 0,
            seedSegmentNodes = null,
            seedSegmentSource = null,
            useOrderedDocumentWindow = false,
            includeLookupSurfaceText = true,
        } = resolvedOptions;
        const collectionStartedAt = performanceNowMs();
        const effectivePostLookupTargets = postLookupTargets;
        const effectiveIncludeClientRects = includeClientRects;
        const isEbookDoc = isEbookContentDocument(doc);
        const collectionVisibleRange = visibleRange;
        if (doc?.defaultView) {
            doc.defaultView.__manabiVisibleSegmentCollectionGeneration = this.visiblePageCollectionGeneration;
        }
        const snapshot = this.visiblePageSegmentSnapshot;
        if (snapshot
            && snapshot.generation === this.visiblePageCollectionGeneration
            && snapshot.doc === doc
            && snapshot.visibleRange === collectionVisibleRange
            && (snapshot.includeSegmentMetadata === true || includeSegmentMetadata === false)
            && (snapshot.includeClientRects === effectiveIncludeClientRects || (snapshot.includeClientRects === true && effectiveIncludeClientRects === false))) {
            manabiTimelineMeasure('visibleSegments.snapshot', collectionStartedAt, {
                reason,
                hit: true,
                includeClientRects: effectiveIncludeClientRects,
                requestedClientRects: includeClientRects,
                postLookupTargets: effectivePostLookupTargets,
                snapshotIncludesClientRects: snapshot.includeClientRects,
                visibleSegmentCount: snapshot.result?.visibleSegments?.length ?? 0,
                source: snapshot.result?.segmentCandidateSource ?? null,
                frameLeft: snapshot.result?.frameLeft ?? null,
                frameTop: snapshot.result?.frameTop ?? null,
                containerLeft: snapshot.result?.containerLeft ?? null,
                containerTop: snapshot.result?.containerTop ?? null,
                firstVisibleSegmentID: snapshot.result?.visibleSegments?.[0]?.node?.id ?? null,
            }, 50);
            if (effectivePostLookupTargets && postIfCached) {
                const postedTargetCount = this.#postVisiblePageLookupTargets(doc, snapshot.result, reason, true);
                if (snapshot.result && postedTargetCount !== null) {
                    snapshot.result.nativeLookupTargetCount = postedTargetCount;
                }
            }
            this.#restoreVisiblePageLookupIndex(doc, snapshot, `${reason}:cached`, prepareLookupIndex, {
                includeSurfaceText: includeLookupSurfaceText,
            });
            this.#hydrateVisiblePageTracking(doc, snapshot.result, `${reason}:cached`, hydrateStatuses, {
                synchronous: hydrateStatusesSynchronously,
                adjacentSegmentCount: hydrateAdjacentStatusSegmentCount,
                allowPartialTrackedWords: hydrateAllowPartialTrackedWords,
                retainHiddenEbookStatusClasses: hydrateRetainHiddenEbookStatusClasses,
            });
            return snapshot.result;
        }
        const result = this.#collectVisiblePageSegmentGeometry(doc, collectionVisibleRange, reason, {
            includeClientRects: effectiveIncludeClientRects,
            includeSegmentMetadata,
            viewportSampleDensity,
            minimumViewportSampleSegmentCount,
            seedSegmentNodes,
            seedSegmentSource,
            useOrderedDocumentWindow,
        });
        const isEmptyBroadEbookResult =
            isEbookContentDocument(doc)
            && (result?.visibleSegments?.length ?? 0) === 0
            && (
                result?.segmentCandidateSource === 'ebook-broad-range-empty'
                || result?.segmentCandidateSource === 'ebook-bounded-empty'
            );
        if (isEmptyBroadEbookResult
            && snapshot
            && snapshot.doc === doc
            && (snapshot.result?.visibleSegments?.length ?? 0) > 0) {
            this.#restoreVisiblePageLookupIndex(doc, snapshot, `${reason}:preserved`, prepareLookupIndex, {
                includeSurfaceText: includeLookupSurfaceText,
            });
            this.#hydrateVisiblePageTracking(doc, snapshot.result, `${reason}:preserved`, hydrateStatuses, {
                synchronous: hydrateStatusesSynchronously,
                adjacentSegmentCount: hydrateAdjacentStatusSegmentCount,
                allowPartialTrackedWords: hydrateAllowPartialTrackedWords,
                retainHiddenEbookStatusClasses: hydrateRetainHiddenEbookStatusClasses,
            });
            return snapshot.result;
        }
        this.visiblePageSegmentSnapshot = {
            generation: this.visiblePageCollectionGeneration,
            doc,
            visibleRange: collectionVisibleRange,
            includeClientRects: effectiveIncludeClientRects,
            includeSegmentMetadata,
            result,
            lookupIndex: this.#prepareVisiblePageLookupIndex(doc, result, reason, prepareLookupIndex, {
                includeSurfaceText: includeLookupSurfaceText,
            }),
        };
        manabiTimelineMeasure('visibleSegments.snapshot', collectionStartedAt, {
            reason,
            hit: false,
            includeClientRects: effectiveIncludeClientRects,
            requestedClientRects: includeClientRects,
            postLookupTargets: effectivePostLookupTargets,
            visibleSegmentCount: result?.visibleSegments?.length ?? 0,
            totalSegmentCount: result?.totalSegmentCount ?? 0,
            source: result?.segmentCandidateSource ?? null,
            frameLeft: result?.frameLeft ?? null,
            frameTop: result?.frameTop ?? null,
            frameWidth: result?.frameWidth ?? null,
            frameHeight: result?.frameHeight ?? null,
            containerLeft: result?.containerLeft ?? null,
            containerTop: result?.containerTop ?? null,
            containerWidth: result?.containerWidth ?? null,
            containerHeight: result?.containerHeight ?? null,
            hasExpectedPaginatorContainer: result?.hasExpectedPaginatorContainer === true,
            firstVisibleSegmentID: result?.visibleSegments?.[0]?.node?.id ?? null,
        }, 50);
        const postedTargetCount = this.#postVisiblePageLookupTargets(doc, result, reason, effectivePostLookupTargets);
        if (result && postedTargetCount !== null) {
            result.nativeLookupTargetCount = postedTargetCount;
        }
        this.#hydrateVisiblePageTracking(doc, result, reason, hydrateStatuses, {
            synchronous: hydrateStatusesSynchronously,
            adjacentSegmentCount: hydrateAdjacentStatusSegmentCount,
            allowPartialTrackedWords: hydrateAllowPartialTrackedWords,
            retainHiddenEbookStatusClasses: hydrateRetainHiddenEbookStatusClasses,
        });
        return result;
    }
    #scheduleNativeLookupHitTargetRefreshSettle(reason = 'unspecified', explicitDoc = null) {
        if (this.#shouldDeferNativeLookupHitTargetRefresh(reason)) {
            this.#deferNativeLookupHitTargetRefresh(reason, explicitDoc);
            return;
        }
        if (this.nativeLookupHitTargetRefreshHandle) {
            cancelAnimationFrame(this.nativeLookupHitTargetRefreshHandle);
            this.nativeLookupHitTargetRefreshHandle = null;
        }
        const generation = (this.nativeLookupHitTargetRefreshGeneration || 0) + 1;
        this.nativeLookupHitTargetRefreshGeneration = generation;
        const scheduledAt = performanceNowMs();
        if (globalThis.__manabiTimelineTraceAll === true) {
        }
        const runRefresh = async () => {
            const docs = isDocumentLike(explicitDoc)
                ? [explicitDoc]
                : this.#lookupContentWindows().map((view) => view.document).filter(isDocumentLike);
            // didDisplay means Foliate has already columnized a usable page. Do not
            // hold its first lookup/status pass behind fonts.ready: remote or custom
            // fonts can settle much later, leaving the initially visible page inert.
            // The document-load font callback schedules one corrective geometry pass
            // if font metrics actually finish after this provisional pass.
            if (generation !== this.nativeLookupHitTargetRefreshGeneration) {
                return;
            }
            const startedAt = performanceNowMs();
            this.nativeLookupHitTargetRefreshHandle = null;
            if (this.#shouldDeferNativeLookupHitTargetRefresh(reason)) {
                this.#deferNativeLookupHitTargetRefresh(reason, explicitDoc);
                return;
            }
            const currentDocs = isDocumentLike(explicitDoc)
                ? [explicitDoc]
                : this.#lookupContentWindows().map((view) => view.document).filter(isDocumentLike);
            try {
                for (const doc of currentDocs) {
                    const visibleRange = this.#visibleRangeForDocument(doc);
                    this.#visiblePageSegmentResult(doc, visibleRange, `scheduled:${reason}`, { postIfCached: true });
                }
            } finally {
                // reader.open() resolves before WebKit's first didDisplay/columnization pass.
                // Keep noncritical native work suppressed through this first visible target and
                // status refresh, which is the deterministic point at which the page is ready
                // for interaction. Later page refreshes find no active initial-load lease.
                globalThis.__manabiFinishInitialForegroundCriticalSection?.(
                    `nativeLookupRefresh.completed:${reason}`
                );
            }
            const elapsedMs = performanceNowMs() - startedAt;
            if (globalThis.__manabiTimelineTraceAll === true || elapsedMs >= 50) {
            }
        };
        this.nativeLookupHitTargetRefreshHandle = requestAnimationFrame(() => {
            this.nativeLookupHitTargetRefreshHandle = null;
            void runRefresh();
        });
    }
    #shouldDeferNativeLookupHitTargetRefresh(reason = 'unspecified') {
        if (reason === 'manual') {
            return false;
        }
        return globalThis.__manabiRestoreInProgress === true
            || document.body?.classList?.contains?.('loading') === true
            || this.hasLoadedLastPosition !== true;
    }
    #deferNativeLookupHitTargetRefresh(reason = 'unspecified', explicitDoc = null) {
        this.pendingNativeLookupHitTargetRefresh = {
            reason,
            explicitDoc: isDocumentLike(explicitDoc) && this.hasLoadedLastPosition === true ? explicitDoc : null,
            deferredAtMs: performanceNowMs(),
        };
    }
    #flushPendingNativeLookupHitTargetRefresh(reason = 'unspecified') {
        const pending = this.pendingNativeLookupHitTargetRefresh;
        if (!pending || this.#shouldDeferNativeLookupHitTargetRefresh(`${pending.reason}.flush`)) {
            return;
        }
        this.pendingNativeLookupHitTargetRefresh = null;
        this.visiblePageSegmentSnapshot = null;
        this.#scheduleNativeLookupHitTargetRefreshSettle(`${pending.reason}.flush:${reason}`, pending.explicitDoc);
    }
    completeLastPositionLoad(reason = 'unspecified') {
        this.hasLoadedLastPosition = true;
        // didDisplay may have deferred visible lookup/status enrichment until the
        // restore position became authoritative. Flush at that state transition;
        // otherwise the first relocate is the next event that can hydrate it.
        this.#flushPendingNativeLookupHitTargetRefresh(`last-position-loaded:${reason}`);
    }
    refreshNativeLookupHitTargets(reason = 'manual') {
        if (this.#shouldDeferNativeLookupHitTargetRefresh(reason)) {
            this.#deferNativeLookupHitTargetRefresh(reason);
            return;
        }
        this.visiblePageSegmentSnapshot = null;
        this.#scheduleNativeLookupHitTargetRefreshSettle(reason);
    }
    refreshNativeMarkReadState(reason = 'manual') {
        this.#scheduleNativeMarkReadStateRefresh(reason);
    }
    #updateEbookSubscriptionPreviewPageState({
        localSectionIndex = null,
    } = {}) {
        const isFirstPageInSection = localSectionIndex === 0;
        const docs = this.view?.renderer?.getContents?.()
            ?.map((content) => content?.doc)
            ?.filter(isDocumentLike) || [];
        for (const doc of docs) {
            const body = doc.body;
            if (!body) continue;
            const isSubscribed = body.getAttribute('data-mnb-subscription-is-active') === 'true'
                || body.getAttribute('data-manabi-subscription-is-active') === 'true';
            const previewValue = !isSubscribed && isFirstPageInSection ? 'true' : 'false';
            if (body.getAttribute('data-mnb-ebook-subscription-preview-page') !== previewValue) {
                body.setAttribute('data-mnb-ebook-subscription-preview-page', previewValue);
            }
            if (body.getAttribute('data-manabi-ebook-subscription-preview-page') !== previewValue) {
                body.setAttribute('data-manabi-ebook-subscription-preview-page', previewValue);
            }
        }
    }
    #postBookInsetSnapshot(_event, _extra = {}) {
    }
    async #waitForAnimationFrames(count = 1) {
        const frameCount = Math.max(0, Number(count) || 0);
        for (let index = 0; index < frameCount; index += 1) {
            await new Promise((resolve) => requestAnimationFrame(() => resolve()));
        }
    }
    async #settleInitialPaginatorLayout(reason = 'unknown', { force = false, forceRender = false } = {}) {
        if (MANABI_DISABLE_INITIAL_PAGINATOR_SETTLE) {
            return { rendered: false, reason: 'initial-paginator-settle-disabled' };
        }
        if (this.hasSettledInitialPaginatorLayout && !force) {
            return { rendered: false, reason: 'already-settled' };
        }
        const renderer = this.view?.renderer;
        if (!renderer || typeof renderer.renderIfContainerSizeChanged !== 'function') {
            return { rendered: false, reason: 'unavailable' };
        }
        try {
            applyStoredChromeInsets?.(`initial-paginator-settle.${reason}`);
            let result = await renderer.renderIfContainerSizeChanged(`initial-paginator-settle.${reason}`);
            if (forceRender && !result?.rendered && typeof renderer.render === 'function') {
                await renderer.render();
                result = { ...(result ?? {}), rendered: true, forcedRender: true };
            }
            this.hasSettledInitialPaginatorLayout = true;
            return result ?? { rendered: false, reason: 'unknown' };
        } catch (error) {
            console.error(error);
            this.hasSettledInitialPaginatorLayout = false;
            return { rendered: false, reason: 'error', message: error?.message ?? String(error) };
        }
    }
    #scheduleInitialPaginatorSettle(reason = 'unknown') {
        if (MANABI_DISABLE_INITIAL_PAGINATOR_SETTLE
            || this.hasSettledInitialPaginatorLayout
            || this.initialPaginatorSettleHandle) {
            return;
        }
        const renderer = this.view?.renderer;
        if (!renderer || typeof renderer.renderIfContainerSizeChanged !== 'function') {
            return;
        }
        this.initialPaginatorSettleHandle = requestAnimationFrame(async () => {
            this.initialPaginatorSettleHandle = null;
            await this.#settleInitialPaginatorLayout(reason);
        });
    }
    async #advanceAfterMarkRead() {
        await new Promise((resolve) => setTimeout(resolve, 430));
        if (this.isRTL) {
            await this.view?.goLeft?.();
        } else {
            await this.view?.goRight?.();
        }
    }
    #resetSideNavChevronAnimation(icon, key) {
        if (this.#chevronFadeAnimationFrames[key] !== null) {
            cancelAnimationFrame(this.#chevronFadeAnimationFrames[key]);
            this.#chevronFadeAnimationFrames[key] = null;
        }
        this.#chevronFadeAnimationCleanup[key]?.();
        this.#chevronFadeAnimationCleanup[key] = null;
        icon?.classList?.remove?.('chevron-swipe-fade');
        icon?.closest?.('.side-nav')?.classList?.remove?.('suppress-hover-chevron');
    }
    #showSideNavChevron(icon, key) {
        if (!icon) return;
        if (this.#chevronOpacityState[key] === 'visible'
            && icon.classList.contains('chevron-visible')
            && !icon.classList.contains('chevron-swipe-fade')
            && !icon.style.opacity
            && !icon.style.visibility) {
            return;
        }
        this.#resetSideNavChevronAnimation(icon, key);
        icon.style.removeProperty('opacity');
        icon.style.removeProperty('visibility');
        icon.classList.add('chevron-visible');
        this.#chevronOpacityState[key] = 'visible';
    }
    #hideSideNavChevron(icon, key) {
        if (!icon) return;
        if (this.#chevronOpacityState[key] === 'hidden'
            && !icon.classList.contains('chevron-visible')
            && !icon.classList.contains('chevron-swipe-fade')
            && !icon.style.opacity
            && !icon.style.visibility) {
            return;
        }
        this.#resetSideNavChevronAnimation(icon, key);
        icon.classList.remove('chevron-visible');
        icon.style.removeProperty('opacity');
        icon.style.removeProperty('visibility');
        this.#chevronOpacityState[key] = 'hidden';
    }
    #fadeSideNavChevronAfterFullOpacity(direction) {
        const key = direction === 'left' ? 'l' : 'r';
        const icon = document.querySelector(`#btn-scroll-${direction} .icon`);
        if (!icon) {
            return;
        }
        const button = icon.closest?.('.side-nav') ?? null;
        const clearHoverSuppression = (event = null) => {
            if (event?.type === 'pointermove' && button) {
                const hoveredElement = Number.isFinite(event.clientX) && Number.isFinite(event.clientY)
                    ? document.elementFromPoint(event.clientX, event.clientY)
                    : null;
                const hoveredNavigation = hoveredElement?.closest?.('.side-nav, #nav-bar') ?? null;
                if (hoveredNavigation === button || hoveredNavigation?.id === 'nav-bar') {
                    return;
                }
            }
            button?.classList?.remove?.('suppress-hover-chevron');
            button?.removeEventListener?.('pointerleave', clearHoverSuppression);
            button?.removeEventListener?.('mouseleave', clearHoverSuppression);
            button?.removeEventListener?.('blur', clearHoverSuppression);
            document.removeEventListener?.('pointermove', clearHoverSuppression, true);
        };
        this.#resetSideNavChevronAnimation(icon, key);
        button?.classList?.add?.('suppress-hover-chevron');
        icon.style.removeProperty('opacity');
        icon.style.removeProperty('visibility');
        icon.classList.add('chevron-visible');
        this.#chevronOpacityState[key] = 'visible';

        this.#chevronFadeAnimationFrames[key] = requestAnimationFrame(() => {
            this.#chevronFadeAnimationFrames[key] = null;
            if (!icon.isConnected) {
                return;
            }
            const finish = event => {
                if (event.target !== icon || event.animationName !== 'side-nav-chevron-swipe-fade') {
                    return;
                }
                icon.removeEventListener('animationend', finish);
                if (this.#chevronFadeAnimationCleanup[key] === cleanup) {
                    this.#chevronFadeAnimationCleanup[key] = null;
                }
                icon.classList.remove('chevron-swipe-fade');
                icon.classList.remove('chevron-visible');
                icon.style.removeProperty('opacity');
                icon.style.visibility = 'hidden';
                this.#chevronOpacityState[key] = 'hidden';
                button?.addEventListener?.('pointerleave', clearHoverSuppression, { once: true });
                button?.addEventListener?.('mouseleave', clearHoverSuppression, { once: true });
                button?.addEventListener?.('blur', clearHoverSuppression, { once: true });
                document.addEventListener?.('pointermove', clearHoverSuppression, true);
            };
            const cleanup = () => icon.removeEventListener('animationend', finish);
            this.#chevronFadeAnimationCleanup[key] = cleanup;
            icon.addEventListener('animationend', finish);
            icon.classList.remove('chevron-visible');
            icon.classList.add('chevron-swipe-fade');
            this.#chevronOpacityState[key] = 'fading';
        });
    }
    #onMainDocumentTouchStart(event) {
        if (window.manabiNativePageTurnOwnsDrag === true) {
            this.#mainDocumentSwipeState = null;
            return;
        }
        if (event.touches?.length !== 1) {
            this.#mainDocumentSwipeState = null;
            return;
        }
        const touch = event.changedTouches?.[0];
        const target = event.target;
        if (!touch || !target || target.ownerDocument !== document) {
            this.#mainDocumentSwipeState = null;
            return;
        }
        const isExcludedTouchTarget = target.closest?.('#reader-stage, #side-bar, #page-tracking-container, #nav-hidden-overlay, .side-nav, input, textarea, select, button, a, [role="button"], [contenteditable="true"]');
        const isInteractiveNavTarget = target.closest?.('#progress-wrapper, #nav-primary-text, #nav-hidden-primary-text, #nav-bottom-row input, #nav-bottom-row button, .nav-relocate-button');
        if (isExcludedTouchTarget || isInteractiveNavTarget) {
            this.#mainDocumentSwipeState = null;
            return;
        }
        this.#mainDocumentSwipeState = {
            startX: touch.screenX,
            startY: touch.screenY,
            startClientX: touch.clientX,
            startClientY: touch.clientY,
            startAtMs: Date.now(),
            triggered: false,
            chevronActive: false,
            nativeLookupCancelled: false,
        };
    }
    async #onMainDocumentTouchMove(event) {
        if (window.manabiNativePageTurnOwnsDrag === true) {
            return;
        }
        const state = this.#mainDocumentSwipeState;
        if (!state || state.triggered) {
            return;
        }
        const touch = event.changedTouches?.[0];
        if (!touch) {
            return;
        }
        const dx = touch.screenX - state.startX;
        const dy = touch.screenY - state.startY;
        const minSwipe = 36;
        if (Math.abs(dx) <= Math.abs(dy) || Math.abs(dx) <= 8) {
            if (state.chevronActive) {
                this.view?.dispatchEvent?.(new CustomEvent('sideNavChevronOpacity', {
                    bubbles: true,
                    composed: true,
                    detail: { leftOpacity: '', rightOpacity: '', source: 'ebook-viewer', reason: 'mainDocumentSwipe.move-axis-or-min-dx' },
                }));
                state.chevronActive = false;
            }
            return;
        }
        event.preventDefault();
        const progress = Math.min(1, Math.abs(dx) / minSwipe);
        const swipedLeft = dx < 0;
        const logicalDirection = this.isRTL
            ? (swipedLeft ? 'backward' : 'forward')
            : (swipedLeft ? 'forward' : 'backward');
        const chevronSide = logicalDirection === 'forward'
            ? (this.isRTL ? 'left' : 'right')
            : (this.isRTL ? 'right' : 'left');
        this.view?.dispatchEvent?.(new CustomEvent('sideNavChevronOpacity', {
            bubbles: true,
            composed: true,
            detail: {
                leftOpacity: chevronSide === 'left' ? progress : 0,
                rightOpacity: chevronSide === 'right' ? progress : 0,
                source: 'ebook-viewer',
                reason: 'mainDocumentSwipe.progress',
                logicalDirection,
                chevronSide,
                swipedLeft,
                isRTL: this.isRTL,
            },
        }));
        state.chevronActive = progress > 0;
        if (!state.nativeLookupCancelled && progress >= 0.25) {
            state.nativeLookupCancelled = true;
            this.#invalidateVisiblePageSegmentSnapshot('page-turn-swipe-intent');
        }
        if (Math.abs(dx) <= minSwipe) return;
        state.triggered = true;
        this.#fadeSideNavChevronAfterFullOpacity(chevronSide);
        await this.#runPageTurn({
            stage: 'pageTurn.mainDocumentSwipe',
            markInputSource: `pageTurn.mainDocumentSwipe.${logicalDirection}`,
            details: {
                dx,
                dy,
                progress,
                logicalDirection,
                chevronSide,
                swipedLeft,
                isRTL: this.isRTL,
            },
            move: async () => logicalDirection === 'forward'
                ? await this.view?.next?.()
                : await this.view?.prev?.(),
        });
    }
    #onMainDocumentTouchEnd(event) {
        if (window.manabiNativePageTurnOwnsDrag === true) {
            this.#mainDocumentSwipeState = null;
            return;
        }
        const state = this.#mainDocumentSwipeState;
        if (state?.chevronActive) {
            this.view?.dispatchEvent?.(new CustomEvent('sideNavChevronOpacity', {
                bubbles: true,
                composed: true,
                detail: { leftOpacity: '', rightOpacity: '', source: 'ebook-viewer', reason: 'mainDocumentSwipe.touchend' },
            }));
        }
        this.#mainDocumentSwipeState = null;
    }
    async open(file, options = {}) {
        this.setLoadingIndicator(true, 'reader.open');
        installReaderPresentationState(options?.readerPresentationState ?? globalThis.__manabiReaderPresentationState, 'reader.open');

        this.hasLoadedLastPosition = false
        this.#resetInitialDisplaySettledPromise();
        this.lastCFIPersistenceObservation = null;
        this.unstableCFIs.clear();
        if (this.initialPaginatorSettleHandle) {
            cancelAnimationFrame(this.initialPaginatorSettleHandle);
            this.initialPaginatorSettleHandle = null;
        }
        this.hasSettledInitialPaginatorLayout = false;
        this.view = await getView(file)
        const initialRestore = options?.initialRestore ?? null;
        globalThis.__manabiPostReaderDocStateEvent?.('reader.open.viewAssigned');
        // this.view.renderer.setAttribute('animated', true) // Flows top to bottom instead of like a book...
        if (typeof window.initialLayoutMode !== 'undefined') {
            this.view.renderer.setAttribute('flow', window.initialLayoutMode)
        }
        this.#installVisibleRendererGoToGuard();
        this.view.renderer.addEventListener('goTo', this.#onGoTo.bind(this))
        this.view.renderer.addEventListener('didDisplay', this.#onDidDisplay.bind(this))
        this.view.addEventListener('load', this.#onLoad.bind(this))
        this.view.addEventListener('relocate', this.#onRelocate.bind(this))

        const {
            book
        } = this.view
        this.bookDir = book.dir || 'ltr';
        if (this.bookDir === 'rtl') {
            seedObservedBookWritingDirection('vertical', 'vertical-rl', 'book.pageProgressionDirection');
        }
        this.isRTL = this.bookDir === 'rtl';
        document.body.dir = this.bookDir;
        document.body?.setAttribute?.('data-book-dir', this.bookDir);
        this.navHUD?.setIsRTL(this.isRTL);
        this.navHUD?.setPageTargets(book.pageList ?? []);
        this.view.renderer.setBookContentStyles?.(bookContentStylesPromise)
        this.#applyHideNavigationDueToScrollToBookContent(this.navHUD?.hideNavigationDueToScroll === true, 'reader.open');
        applyStoredChromeInsets('reader.open');
        //        this.view.renderer.next()

        $('#nav-bar').style.visibility = 'visible'
        this.buttons = {
            prev: document.getElementById('btn-prev-chapter'),
            next: document.getElementById('btn-next-chapter'),
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
        const runSideButtonPageTurn = async (side, method, button, eventType) => {
            const compactDisabled = isCompactNavigationSheetSidePaginationDisabled();
            if (button?.disabled || compactDisabled) {
                return;
            }
            if (side === 'left' || side === 'right') {
                this.#fadeSideNavChevronAfterFullOpacity(side);
            }
            await this.#runPageTurn({
                stage: 'pageTurn.sideButton',
                markInputSource: `pageTurn.sideButton.${eventType ?? 'unknown'}`,
                details: {
                    side,
                    method,
                    eventType,
                },
                move: async () => method === 'goLeft'
                    ? await this.view.goLeft()
                    : await this.view.goRight(),
            });
        };
        const leftSideBtn = document.getElementById('btn-scroll-left');
        if (leftSideBtn) leftSideBtn.addEventListener('click', async () => {
            const now = Date.now();
            if (globalThis.__manabiLastSideButtonTouchActivation?.side === 'left'
                && now - globalThis.__manabiLastSideButtonTouchActivation.timestamp < 700) {
                return;
            }
            await runSideButtonPageTurn('left', 'goLeft', leftSideBtn, 'click');
        });
        const rightSideBtn = document.getElementById('btn-scroll-right');
        if (rightSideBtn) rightSideBtn.addEventListener('click', async () => {
            const now = Date.now();
            if (globalThis.__manabiLastSideButtonTouchActivation?.side === 'right'
                && now - globalThis.__manabiLastSideButtonTouchActivation.timestamp < 700) {
                return;
            }
            await runSideButtonPageTurn('right', 'goRight', rightSideBtn, 'click');
        });

        // Immediate tap feedback for side-nav chevrons on iOS/touch
        document.querySelectorAll('.side-nav').forEach(nav => {
            nav.addEventListener('touchstart', (event) => {
                if (nav.disabled || isCompactNavigationSheetSidePaginationDisabled()) return;
                nav.classList.add('pressed');
            }, {
                passive: true
            });
            nav.addEventListener('touchend', (event) => {
                nav.classList.remove('pressed');
                if (nav.disabled || isCompactNavigationSheetSidePaginationDisabled()) return;
                const side = nav.id === 'btn-scroll-left' ? 'left' : (nav.id === 'btn-scroll-right' ? 'right' : null);
                const method = side === 'left' ? 'goLeft' : (side === 'right' ? 'goRight' : null);
                if (side && method) {
                    event.preventDefault?.();
                    globalThis.__manabiLastSideButtonTouchActivation = {
                        side,
                        timestamp: Date.now(),
                    };
                    runSideButtonPageTurn(side, method, nav, 'touchend').catch((error) => console.error(error));
                }
            });
            nav.addEventListener('touchcancel', () => {
                nav.classList.remove('pressed');
            });
        });

        // Side-nav opacity wiring
        this.view.addEventListener('sideNavChevronOpacity', e => {
            const l = document.querySelector('#btn-scroll-left .icon');
            const r = document.querySelector('#btn-scroll-right .icon');

            const applyChevronOpacity = (elem, value, key) => {
                if (!elem) {
                    return;
                }

                // Show chevron at full opacity
                if (Number(value) >= 1) {
                    this.#showSideNavChevron(elem, key);
                    return;
                }

                // Show chevron at partial opacity
                if (Number(value) > 0) {
                    const nextOpacity = String(Math.round(Number(value) * 100) / 100);
                    if (this.#chevronOpacityState[key] === nextOpacity
                        && elem.style.opacity === nextOpacity
                        && elem.style.visibility === 'visible'
                        && !elem.classList.contains('chevron-visible')
                        && !elem.classList.contains('chevron-swipe-fade')) {
                        return;
                    }
                    this.#resetSideNavChevronAnimation(elem, key);
                    elem.classList.remove('chevron-visible');
                    elem.style.opacity = nextOpacity;
                    elem.style.visibility = 'visible';
                    this.#chevronOpacityState[key] = nextOpacity;
                    return;
                }

                this.#hideSideNavChevron(elem, key);
            };

            if (e.detail.fadeOutAfterFullOpacity === true) {
                const chevronSide = e.detail.chevronSide === 'left' || e.detail.chevronSide === 'right'
                    ? e.detail.chevronSide
                    : (Number(e.detail.leftOpacity) > 0 ? 'left' : (Number(e.detail.rightOpacity) > 0 ? 'right' : null));
                if (chevronSide) {
                    this.#fadeSideNavChevronAfterFullOpacity(chevronSide);
                } else {
                    applyChevronOpacity(l, e.detail.leftOpacity, 'l');
                    applyChevronOpacity(r, e.detail.rightOpacity, 'r');
                }
                return;
            }

            applyChevronOpacity(l, e.detail.leftOpacity, 'l');
            applyChevronOpacity(r, e.detail.rightOpacity, 'r');
        });
        // Listen for resetSideNavChevrons custom event to reset chevrons
        document.addEventListener('resetSideNavChevrons', e => {
            this.#resetSideNavChevrons();
        });

        // Section ticks
        const sizes = book.sections.filter(s => s.linear !== 'no').map(s => s.size)
        const total = sizes.reduce((a, b) => a + b, 0)
        let sum = 0
        // Calculate all tick positions as fractions
        let ticks = [];
        for (const size of sizes.slice(0, -1)) {
            sum += size;
            ticks.push(sum / total);
        }
        if (sizes.length >= 50) {
            // Collapse ticks that are close to each other, never collapse more than those within that window.
            const THRESHOLD = 0.01;
            let collapsed = [];
            let group = [];
            for (let i = 0; i < ticks.length; ++i) {
                group.push(ticks[i]);
                // If next tick is far enough, close group
                if (i === ticks.length - 1 || Math.abs(ticks[i + 1] - ticks[i]) > THRESHOLD) {
                    // Collapse group if there's more than one tick in threshold
                    if (group.length > 1) {
                        // Pick the tick closest to the middle of the group
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
            ticks = collapsed;
        }
        // Render section ticks into the custom overlay container used by the January toolbar.
        const tickContainer = document.getElementById('progress-ticks');
        if (tickContainer) {
            tickContainer.innerHTML = '';
            for (const tick of ticks) {
                if (!Number.isFinite(tick)) continue;
                const pos = Math.max(0, Math.min(1, tick)) * 100;
                const mark = document.createElement('div');
                mark.className = 'tick';
                mark.style[this.isRTL ? 'right' : 'left'] = `${pos}%`;
                tickContainer.append(mark);
            }
        }

        // Percent jump input/button wiring
        const percentInput = document.getElementById('percent-jump-input');
        const percentButton = document.getElementById('percent-jump-button');

        percentInput.addEventListener('input', () => {
            const value = parseFloat(percentInput.value);
            const valid = !isNaN(value) && value >= 0 && value <= 100 && value !== this.lastPercentValue;
            percentButton.disabled = !valid;
        });

        percentButton.addEventListener('click', () => {
            const value = parseFloat(percentInput.value);
            if (!isNaN(value) && value >= 0 && value <= 100) {
                this.lastPercentValue = value;
                percentButton.disabled = true;
                this.goToPercent(value, 'sidebar-percent-jump-button');
            }
        });

        document.addEventListener('keydown', this.#handleKeydown.bind(this))

        let pendingMainDocumentBlankNavigationTouch = null;
        let lastPostedMainDocumentBlankTouchTap = null;
        const shouldSuppressMainDocumentSyntheticMouseBlankTap = (event, now) => {
            if (event.type !== 'mousedown') {
                return false;
            }
            if (event.sourceCapabilities?.firesTouchEvents === true) {
                return true;
            }
            const lastTouchTap = lastPostedMainDocumentBlankTouchTap;
            lastPostedMainDocumentBlankTouchTap = null;
            if (!lastTouchTap) {
                return false;
            }
            const point = manabiEventScreenPoint(event);
            if (!point || point.x === null || point.y === null) {
                return true;
            }
            const dx = point.x - lastTouchTap.x;
            const dy = point.y - lastTouchTap.y;
            return (dx * dx + dy * dy) <= (manabiSyntheticTouchMouseDistanceThreshold * manabiSyntheticTouchMouseDistanceThreshold);
        };
        const postNoElementNavigationTouchStart = (event, source, touchstartAtMs = Date.now()) => {
            const now = Date.now();
            if (shouldSuppressMainDocumentSyntheticMouseBlankTap(event, now)) {
                return;
            }
            const ebookNavigationHidden =
                globalThis.reader?.navHUD?.hideNavigationDueToScroll === true
                || document?.body?.__manabiNavigationHiddenDueToScroll === true
                || document?.body?.classList?.contains?.('nav-hidden-due-to-scroll') === true;
            if (event.type === 'touchend') {
                const point = manabiEventScreenPoint(event);
                lastPostedMainDocumentBlankTouchTap = point && point.x !== null && point.y !== null
                    ? {
                        x: point.x,
                        y: point.y,
                    }
                    : null;
            }
            window.webkit?.messageHandlers?.touchstartCallbackHandler?.postMessage?.({
                touchedEntryWithElementId: null,
                wasAlreadySelected: false,
                touchstartAtMs,
                touchstartEventType: event.type,
                ebookNavigationHidden,
                source,
            });
        };
        const clearPendingMainDocumentBlankNavigationTouch = () => {
            pendingMainDocumentBlankNavigationTouch = null;
        };
        const touchPointForNavigationGesture = event => event.changedTouches?.[0] ?? event.touches?.[0] ?? event;
        const movedPastBlankNavigationTapThreshold = (event, pending) => {
            const point = touchPointForNavigationGesture(event);
            const dx = (point?.screenX ?? point?.clientX ?? pending.startX) - pending.startX;
            const dy = (point?.screenY ?? point?.clientY ?? pending.startY) - pending.startY;
            return (dx * dx + dy * dy) > (manabiBlankNavigationMoveThreshold * manabiBlankNavigationMoveThreshold);
        };
        const processTouchStart = function(event) {
            // Ignore touches inside foliate-js viewer iframe
            const target = event.target;
            if (target && target.ownerDocument !== document) {
                return
            }
            const excludedTarget = target?.closest?.('#side-bar, #page-tracking-container, #nav-bar, #nav-hidden-overlay, .side-nav, input, textarea, select, [contenteditable="true"]');
            if (excludedTarget) {
                clearPendingMainDocumentBlankNavigationTouch();
                return
            }

            if (event.type === 'touchstart') {
                const point = touchPointForNavigationGesture(event);
                pendingMainDocumentBlankNavigationTouch = point
                    ? {
                        startX: point.screenX ?? point.clientX,
                        startY: point.screenY ?? point.clientY,
                        startAtMs: Date.now(),
                    }
                    : null;
                return;
            }
            postNoElementNavigationTouchStart(event, 'main-document.blank')
        }
        const processMainDocumentBlankNavigationTouchMove = function(event) {
            const pending = pendingMainDocumentBlankNavigationTouch;
            if (!pending) {
                return;
            }
            if (movedPastBlankNavigationTapThreshold(event, pending)) {
                clearPendingMainDocumentBlankNavigationTouch();
            }
        }
        const processMainDocumentBlankNavigationTouchEnd = function(event) {
            const pending = pendingMainDocumentBlankNavigationTouch;
            clearPendingMainDocumentBlankNavigationTouch();
            if (!pending || event.type === 'touchcancel') {
                return;
            }
            if (movedPastBlankNavigationTapThreshold(event, pending)) {
                return;
            }
            postNoElementNavigationTouchStart(event, 'main-document.blank', pending.startAtMs)
        }
        let pendingChromeBlankNavigationTouch = null;
        const clearPendingChromeBlankNavigationTouch = () => {
            pendingChromeBlankNavigationTouch = null;
        };
        const beginChromeBlankNavigationTouch = function(event, source) {
            if (event.type === 'touchstart') {
                const point = touchPointForNavigationGesture(event);
                pendingChromeBlankNavigationTouch = point
                    ? {
                        startX: point.screenX ?? point.clientX,
                        startY: point.screenY ?? point.clientY,
                        startAtMs: Date.now(),
                        source,
                    }
                    : null;
                return;
            }
            postNoElementNavigationTouchStart(event, `${source}.mouse`);
        };
        const processChromeBlankNavigationTouchMove = function(event) {
            const pending = pendingChromeBlankNavigationTouch;
            if (!pending) {
                return;
            }
            if (movedPastBlankNavigationTapThreshold(event, pending)) {
                clearPendingChromeBlankNavigationTouch();
            }
        };
        const processChromeBlankNavigationTouchEnd = function(event) {
            const pending = pendingChromeBlankNavigationTouch;
            clearPendingChromeBlankNavigationTouch();
            if (!pending || event.type === 'touchcancel') {
                return;
            }
            if (movedPastBlankNavigationTapThreshold(event, pending)) {
                return;
            }
            postNoElementNavigationTouchStart(event, pending.source, pending.startAtMs);
        };
        const processNavChromeTouchStart = function(event) {
            const target = event.target;
            if (target && target.ownerDocument !== document) {
                return;
            }
            const navBar = target?.closest?.('#nav-bar');
            if (!navBar) {
                return;
            }
            const interactiveTarget = target?.closest?.('a, button, input, textarea, select, [role="button"], [contenteditable="true"], #progress-wrapper');
            if (interactiveTarget) {
                clearPendingChromeBlankNavigationTouch();
                return;
            }
            beginChromeBlankNavigationTouch(event, 'nav-bar.chrome');
        }
        const processPageTrackingChromeTouchStart = function(event) {
            const target = event.target;
            if (target && target.ownerDocument !== document) {
                return;
            }
            const pageTrackingContainer = target?.closest?.('#page-tracking-container');
            if (!pageTrackingContainer) {
                return;
            }
            const pageReadButton = target?.closest?.('.page-read-button');
            if (pageReadButton) {
                clearPendingChromeBlankNavigationTouch();
                return;
            }
            beginChromeBlankNavigationTouch(event, 'page-tracking.chrome');
        }
        document.addEventListener('touchstart', processNavChromeTouchStart, {
            passive: true
        })
        document.addEventListener('mousedown', processNavChromeTouchStart, {
            passive: true
        })
        document.addEventListener('touchstart', processPageTrackingChromeTouchStart, {
            passive: true
        })
        document.addEventListener('mousedown', processPageTrackingChromeTouchStart, {
            passive: true
        })
        document.addEventListener('touchmove', processChromeBlankNavigationTouchMove, {
            passive: true
        })
        document.addEventListener('touchend', processChromeBlankNavigationTouchEnd, {
            passive: true
        })
        document.addEventListener('touchcancel', processChromeBlankNavigationTouchEnd, {
            passive: true
        })
        document.addEventListener('touchstart', processTouchStart, {
            passive: true
        })
        document.addEventListener('touchmove', processMainDocumentBlankNavigationTouchMove, {
            passive: true
        })
        document.addEventListener('touchend', processMainDocumentBlankNavigationTouchEnd, {
            passive: true
        })
        document.addEventListener('touchcancel', processMainDocumentBlankNavigationTouchEnd, {
            passive: true
        })
        document.addEventListener('mousedown', processTouchStart, {
            passive: true
        })
        document.addEventListener('touchstart', this.#onMainDocumentTouchStart.bind(this), {
            passive: true,
        });
        document.addEventListener('touchmove', this.#onMainDocumentTouchMove.bind(this), {
            passive: false,
        });
        document.addEventListener('touchend', this.#onMainDocumentTouchEnd.bind(this), {
            passive: true,
        });
        document.addEventListener('touchcancel', this.#onMainDocumentTouchEnd.bind(this), {
            passive: true,
        });


        const title = book.metadata?.title ?? 'Untitled Book'
        document.title = title
        $('#side-bar-title').innerText = title
        this.navHUD?.setBookTitle?.(title)
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
        this.#bookForSidebarCover = book
        this.#sidebarCoverLoadPromise = null
        if (this.#sidebarCoverObjectURL) {
            URL.revokeObjectURL(this.#sidebarCoverObjectURL)
            this.#sidebarCoverObjectURL = null
        }
        $('#side-bar-cover')?.removeAttribute?.('src')

        applyStoredChromeInsets('reader.open.beforeInitialDisplay');
        await this.#displayInitialSection('reader.open', initialRestore);
        this.#schedulePostInitialOpenWork(book);
    }

    #schedulePostInitialOpenWork(book) {
        setTimeout(() => {
            void this.#runPostInitialOpenWork(book).catch((error) => {
                console.error(error);
            });
        }, 0);
    }

    async #runPostInitialOpenWork(book) {
        const toc = book.toc
        if (toc && !this.#tocView) {
            this.#tocView = createTOCView(toc, async (href) => {
                await runWithNavigationIntent({
                    source: 'toc',
                    target: 'view.goTo',
                    href,
                }, () => this.view.goTo(href)).catch(e => console.error(e))
                this.closeSideBar()
            })
            $('#toc-view').append(this.#tocView.element)
        }

        // load and show highlights embedded in the file by Calibre
        let bookmarks;
        try {
            bookmarks = await book.getCalibreBookmarks?.()
        } catch (error) {
            return;
        }
        if (bookmarks) {
            const {
                fromCalibreHighlight
            } = await import('./epubcfi.js')
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
            this.view.addEventListener('create-overlay', e => {
                const {
                    index
                } = e.detail
                const list = this.annotations.get(index)
                if (list)
                    for (const annotation of list)
                        this.view.addAnnotation(annotation)
                        })
            this.view.addEventListener('draw-annotation', e => {
                const {
                    draw,
                    annotation
                } = e.detail
                const {
                    color
                } = annotation
                draw(Overlayer.highlight, {
                    color
                })
                        })
            this.view.addEventListener('show-annotation', e => {
                const annotation = this.annotationsByValue.get(e.detail.value)
                if (annotation.note) alert(annotation.note)
                    })
        }
    }

    async #displayInitialSection(reason = 'reader.open', initialRestore = null) {
        const initialRestoreRequestID = typeof initialRestore?.requestID === 'string' && initialRestore.requestID.length > 0
            ? initialRestore.requestID
            : null;
        const requestedLocatorFromBridge = typeof initialRestore?.requestedLocator === 'string'
            ? initialRestore.requestedLocator
            : null;
        const initialRestoreFraction = coerceRestoreFraction(initialRestore?.fractionalCompletion);
        const hasInitialRestoreFraction = initialRestoreFraction != null && initialRestoreFraction > 0;
        const syntheticInitialRestore = hasInitialRestoreFraction ? null : parseSyntheticRestoreLocator(initialRestore?.cfi);
        const spineOnlyInitialRestoreSectionIndex = !syntheticInitialRestore && !hasInitialRestoreFraction
            ? parseSpineOnlyEpubCFI(initialRestore?.cfi)
            : null;
        const hasSpineOnlyInitialRestore = Number.isInteger(spineOnlyInitialRestoreSectionIndex);
        const initialRestoreCFI = !syntheticInitialRestore
            && !hasSpineOnlyInitialRestore
            && !hasInitialRestoreFraction
            && typeof initialRestore?.cfi === 'string'
            ? initialRestore.cfi
            : '';
        const hasInitialRestoreCFI = initialRestoreCFI.length > 0;
        const restoreLocatorKind = syntheticInitialRestore
            ? 'synthetic'
            : (
                hasSpineOnlyInitialRestore
                    ? 'spine-cfi'
                    : (hasInitialRestoreFraction ? 'fraction' : (hasInitialRestoreCFI ? 'cfi' : 'none'))
            );
        const publishInitialRestoreResult = (terminalState, details = {}) => {
            const location = details.location ?? this.view?.lastLocation ?? null;
            return manabiPublishInitialRestoreResult(manabiCreateInitialRestoreResult({
                requestID: initialRestoreRequestID,
                terminalState,
                requestedLocator: requestedLocatorFromBridge ?? restoreLocatorKind,
                resolvedLocator: restoreLocatorKind,
                requestedFraction: hasInitialRestoreFraction ? initialRestoreFraction : null,
                requestedCFI: initialRestore?.cfi,
                location,
                navigationOk: details.navigationOk ?? null,
                error: details.error ?? null,
                reason,
                startedAt: details.startedAt ?? null,
                restorePrecision: details.restorePrecision ?? null,
                restoreDegraded: details.restoreDegraded ?? null,
                fractionTolerance: details.fractionTolerance ?? null,
            }));
        };
        if (!this.view?.renderer || this.initialDisplaySettled) {
            globalThis.__manabiRestoreDebugLog?.('ebook.initialDisplay.return', {
                reason,
                path: !this.view?.renderer ? 'missing-renderer' : 'already-settled',
                hasRenderer: !!this.view?.renderer,
                initialDisplaySettled: this.initialDisplaySettled === true,
                hasInitialRestore: !!initialRestore,
            });
            if (initialRestore) {
                publishInitialRestoreResult(!this.view?.renderer ? 'failed' : 'skipped', {
                    error: !this.view?.renderer ? 'missing-renderer' : 'already-settled',
                    startedAt: performanceNowMs(),
                });
            }
            return true;
        }
        const startedAt = performanceNowMs();
        const hasInitialRestoreTarget = !!syntheticInitialRestore
            || hasSpineOnlyInitialRestore
            || hasInitialRestoreCFI
            || hasInitialRestoreFraction;
        const runInitialDisplayNavigation = async (intent, operation) => {
            const navigationStartedAt = performanceNowMs();
            const previousIntent = globalThis.__manabiNavigationIntent ?? null;
            const activeIntent = {
                timestamp: Date.now(),
                ...intent,
            };
            globalThis.__manabiNavigationIntent = activeIntent;
            try {
                const operationResult = operation();
                const operationPromise = Promise.resolve(operationResult);
                const displaySettledPromise = this.initialDisplaySettledPromise
                    ? this.initialDisplaySettledPromise.then((settled) => ({
                        settledBy: 'display',
                        result: settled,
                    }))
                    : null;
                operationPromise
                    .then((result) => {
                        this.initialDisplayNavigationPending = false;
                        this.#settleInitialDisplayFromVisibleContent(`${reason}.initialDisplay.operationComplete`);
                        return {
                            settledBy: 'operation',
                            result,
                        };
                    })
                    .catch((error) => {
                        this.initialDisplayNavigationPending = false;
                        globalThis.__manabiRestoreDebugLog?.('ebook.initialDisplay.navigation.asyncError', {
                            reason,
                            restoreLocatorKind,
                            source: intent?.source ?? null,
                            target: intent?.target ?? null,
                            error: error?.message || String(error),
                        });
                    });
                const restoreIntentWhenSettled = displaySettledPromise
                    ? Promise.race([
                        operationPromise.catch(() => null),
                        displaySettledPromise.catch(() => null),
                    ])
                    : operationPromise.catch(() => null);
                Promise.resolve(restoreIntentWhenSettled).finally(() => {
                    if (globalThis.__manabiNavigationIntent === activeIntent) {
                        globalThis.__manabiNavigationIntent = previousIntent;
                    }
                });
                if (operationResult && typeof operationResult.then !== 'function') {
                    this.initialDisplayNavigationPending = false;
                    this.#settleInitialDisplayFromVisibleContent(`${reason}.initialDisplay.operationComplete`);
                } else {
                    this.initialDisplayNavigationPending = true;
                }
                return {
                    ok: true,
                    result: operationResult,
                    pending: operationResult && typeof operationResult.then === 'function',
                };
            } catch (error) {
                if (globalThis.__manabiNavigationIntent === activeIntent) {
                    globalThis.__manabiNavigationIntent = previousIntent;
                }
                globalThis.__manabiRestoreDebugLog?.('ebook.initialDisplay.navigation.error', {
                    reason,
                    restoreLocatorKind,
                    source: intent?.source ?? null,
                    target: intent?.target ?? null,
                    error: error?.message || String(error),
                    requestedFraction: hasInitialRestoreFraction ? safeRound(initialRestoreFraction, 6) : null,
                });
                return {
                    ok: false,
                    error,
                };
            }
        };
        globalThis.__manabiRestoreDebugLog?.('ebook.initialDisplay.start', {
            reason,
            restoreLocatorKind,
            hasInitialRestore: !!initialRestore,
            initialCFILength: typeof initialRestore?.cfi === 'string' ? initialRestore.cfi.length : 0,
            initialCFIPrefix: hasInitialRestoreCFI ? initialRestoreCFI.slice(0, 24) : null,
            requestedFraction: hasInitialRestoreFraction ? safeRound(initialRestoreFraction, 6) : null,
            syntheticSectionIndex: syntheticInitialRestore?.sectionIndex ?? null,
            syntheticLocalPage: syntheticInitialRestore?.localSectionIndex ?? null,
            spineSectionIndex: spineOnlyInitialRestoreSectionIndex ?? null,
            rawFractionType: typeof initialRestore?.fractionalCompletion,
            rawFractionValue: initialRestore?.fractionalCompletion ?? null,
            initialDisplaySettled: this.initialDisplaySettled === true,
            hasLoadedLastPosition: this.hasLoadedLastPosition === true,
        });
        try {
            let intent;
            let operation;
            if (syntheticInitialRestore) {
                intent = {
                    source: `${reason}.initialRestore`,
                    target: 'renderer.goTo',
                    sectionIndex: syntheticInitialRestore.sectionIndex,
                    localPage: syntheticInitialRestore.localSectionIndex,
                    rendererTotal: syntheticInitialRestore.rendererTotal,
                };
                operation = () => this.view.renderer.goTo?.({
                    index: syntheticInitialRestore.sectionIndex,
                    localPage: syntheticInitialRestore.localSectionIndex,
                });
            } else if (hasSpineOnlyInitialRestore) {
                if (hasInitialRestoreFraction) {
                    intent = {
                        source: `${reason}.initialRestoreSpineCFIFraction`,
                        target: 'view.goToFraction',
                        spineSectionIndex: spineOnlyInitialRestoreSectionIndex,
                        fraction: initialRestoreFraction,
                    };
                    operation = () => this.view.goToFraction(initialRestoreFraction);
                } else {
                    intent = {
                        source: `${reason}.initialRestoreSpineCFI`,
                        target: 'renderer.goTo',
                        sectionIndex: spineOnlyInitialRestoreSectionIndex,
                    };
                    operation = () => this.view.renderer.goTo?.({
                        index: spineOnlyInitialRestoreSectionIndex,
                    });
                }
            } else if (hasInitialRestoreFraction) {
                intent = {
                    source: `${reason}.initialRestoreFraction`,
                    target: 'view.goToFraction',
                    fraction: initialRestoreFraction,
                    cfiAvailable: hasInitialRestoreCFI,
                };
                operation = () => this.view.goToFraction(initialRestoreFraction);
            } else if (hasInitialRestoreCFI) {
                intent = {
                    source: `${reason}.initialRestoreCFI`,
                    target: 'view.goTo',
                    cfiLength: initialRestoreCFI.length,
                };
                operation = async () => {
                    return await this.view.goTo(initialRestoreCFI);
                };
            } else {
                intent = {
                    source: reason,
                    target: 'renderer.firstSection',
                };
                operation = () => this.view.renderer.firstSection?.();
            }
            globalThis.__manabiRestoreDebugLog?.('ebook.initialDisplay.navigationIntent', {
                reason,
                restoreLocatorKind,
                source: intent?.source ?? null,
                target: intent?.target ?? null,
                sectionIndex: intent?.sectionIndex ?? null,
                spineSectionIndex: intent?.spineSectionIndex ?? null,
                localPage: intent?.localPage ?? null,
                cfiLength: intent?.cfiLength ?? null,
                requestedFraction: hasInitialRestoreFraction ? safeRound(initialRestoreFraction, 6) : null,
                rawFractionType: typeof initialRestore?.fractionalCompletion,
                rawFractionValue: initialRestore?.fractionalCompletion ?? null,
            });
            const navigationResult = await runInitialDisplayNavigation(intent, operation);
            // With no saved locator, successfully dispatching the first-section navigation
            // makes the position authoritative immediately. Keeping the restore gate closed
            // here permanently defers initial lookup targets and tracking highlights because
            // there is no later native loadLastPosition call required to release it.
            if (!hasInitialRestoreTarget && navigationResult?.ok === true) {
                this.completeLastPositionLoad('initial-display-no-restore-target');
            }
            let displaySettled = this.#settleInitialDisplayFromVisibleContent(`${reason}.initialDisplay.navigationComplete`);
            const location = this.view?.lastLocation ?? null;
            const settledSectionIndex = typeof location?.section?.current === 'number'
                ? location.section.current
                : (typeof location?.sectionIndex === 'number' ? location.sectionIndex : null);
            const settledFraction = typeof location?.fraction === 'number' ? location.fraction : null;
            const initialRestoreRequested = hasInitialRestoreTarget;
            const initialRestoreFractionTolerance = 0.003;
            const pendingNavigationHasVisibleContent = navigationResult?.pending === true
                ? displaySettled?.settled === true
                : true;
            const initialRestoreFractionSatisfied = hasInitialRestoreFraction && !syntheticInitialRestore
                ? (
                    typeof settledFraction === 'number'
                    && Math.abs(settledFraction - initialRestoreFraction) <= initialRestoreFractionTolerance
                )
                : (navigationResult?.ok === true && pendingNavigationHasVisibleContent);
            const spineOnlyRestoreIsPreciseEnough =
                !hasSpineOnlyInitialRestore || hasInitialRestoreFraction;
            const initialRestoreWillBeMarkedHandled =
                initialRestoreRequested
                && initialRestoreFractionSatisfied
                && pendingNavigationHasVisibleContent
                && spineOnlyRestoreIsPreciseEnough;
            const initialRestoreFractionDelta = hasInitialRestoreFraction && typeof settledFraction === 'number'
                ? Math.abs(settledFraction - initialRestoreFraction)
                : null;
            const initialRestoreUsedSyntheticFallback =
                !!syntheticInitialRestore && initialRestoreWillBeMarkedHandled;
            const initialRestoreDegraded =
                initialRestoreUsedSyntheticFallback
                && hasInitialRestoreFraction
                && typeof initialRestoreFractionDelta === 'number'
                && initialRestoreFractionDelta > initialRestoreFractionTolerance;
            const restorePrecision = initialRestoreWillBeMarkedHandled
                ? (initialRestoreUsedSyntheticFallback
                    ? 'synthetic-fraction-fallback'
                    : (hasInitialRestoreCFI ? 'cfi' : (hasInitialRestoreFraction ? 'fraction' : 'section')))
                : null;
            globalThis.__manabiRestoreDebugLog?.('ebook.initialDisplay.settleCheck', {
                reason,
                restoreLocatorKind,
                initialRestoreRequested,
                hasInitialRestoreFraction,
                requestedFraction: hasInitialRestoreFraction ? safeRound(initialRestoreFraction, 6) : null,
                settledFraction: typeof settledFraction === 'number' ? safeRound(settledFraction, 6) : null,
                fractionDelta: initialRestoreFractionDelta != null ? safeRound(initialRestoreFractionDelta, 6) : null,
                fractionTolerance: safeRound(initialRestoreFractionTolerance, 6),
                navigationOk: navigationResult?.ok === true,
                initialRestoreFractionSatisfied,
                spineOnlyRestoreIsPreciseEnough,
                initialRestoreWillBeMarkedHandled,
                restorePrecision,
                restoreDegraded: initialRestoreDegraded,
                settledSectionIndex,
                settledReason: displaySettled?.reason ?? null,
            });
            globalThis.__manabiRestoreDebugLog?.('ebook.initialDisplay.finish', {
                reason,
                restoreLocatorKind,
                requestedFraction: hasInitialRestoreFraction ? safeRound(initialRestoreFraction, 6) : null,
                settledSectionIndex,
                lastLocationFraction: typeof settledFraction === 'number' ? safeRound(settledFraction, 6) : null,
                lastLocationCurrent: location?.location?.current ?? null,
                lastLocationTotal: location?.location?.total ?? null,
                initialRestoreWillBeMarkedHandled,
                restorePrecision,
                restoreDegraded: initialRestoreDegraded,
                spineOnlyRestoreIsPreciseEnough,
                navigationOk: navigationResult?.ok === true,
            });
            const terminalRestoreResult = publishInitialRestoreResult(
                initialRestoreWillBeMarkedHandled
                    ? 'satisfied'
                    : (initialRestoreRequested ? 'failed' : 'noTarget'),
                {
                    location,
                    navigationOk: navigationResult?.ok === true,
                    startedAt,
                    restorePrecision,
                    restoreDegraded: initialRestoreDegraded,
                    fractionTolerance: initialRestoreFractionTolerance,
                }
            );
            if (initialRestoreWillBeMarkedHandled) {
                this.initialDisplayNavigationPending = false;
                this.completeLastPositionLoad('initial-display-restore-satisfied');
                clearInitialRestoreRenderReadyGate('initialDisplay.restoreSatisfied');
                markReaderRenderReady('initialDisplay.restoreSatisfied');
                globalThis.__manabiInitialRestoreHandled = {
                    cfi: typeof initialRestore?.cfi === 'string' ? initialRestore.cfi : '',
                    fractionalCompletion: terminalRestoreResult.handledFractionalCompletion,
                    sectionIndex: syntheticInitialRestore?.sectionIndex ?? settledSectionIndex,
                    localSectionIndex: syntheticInitialRestore?.localSectionIndex ?? null,
                    rendererTotal: syntheticInitialRestore?.rendererTotal ?? null,
                    fractionalAnchorSuppressed: !!syntheticInitialRestore,
                    handledAtMs: Date.now(),
                };
                globalThis.__manabiRestoreDebugLog?.('ebook.initialDisplay.handledSet', {
                    reason,
                    restoreLocatorKind,
                    requestedSectionIndex: syntheticInitialRestore?.sectionIndex ?? null,
                    requestedLocalPage: syntheticInitialRestore?.localSectionIndex ?? null,
                    cfiLength: typeof initialRestore?.cfi === 'string' ? initialRestore.cfi.length : 0,
                    settledSectionIndex,
                    lastLocationFraction: typeof settledFraction === 'number' ? safeRound(settledFraction, 6) : null,
                    lastLocationCurrent: location?.location?.current ?? null,
                    lastLocationTotal: location?.location?.total ?? null,
                });
            } else if (initialRestoreRequested) {
            }
            return true;
        } catch (error) {
            publishInitialRestoreResult(hasInitialRestoreTarget ? 'failed' : 'noTarget', {
                error: error?.message || String(error),
                navigationOk: false,
                startedAt,
            });
            return false;
        }
    }

    async displayInitialSection(reason = 'external', initialRestore = null) {
        return this.#displayInitialSection(reason, initialRestore);
    }

    async updateNavButtons() {
        const navVisibilityBefore = captureNavVisibilityState();
        // Remove any nav-spinner left over from chapter navigation click
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
        const pageMetrics = typeof r.pageMetrics === "function" ? await r.pageMetrics() : null;
        // Use new section start/end helpers if available
        const atSectionStart = pageMetrics
            ? pageMetrics.page <= 1
            : (typeof r.isAtSectionStart === "function" ? await r.isAtSectionStart() : false);
        const atSectionEnd = pageMetrics
            ? pageMetrics.page >= pageMetrics.pages - 2
            : (typeof r.isAtSectionEnd === "function" ? await r.isAtSectionEnd() : false);
        // Use public helpers to detect prev/next section
        const hasPrevSection = typeof r.getHasPrevSection === "function" ? await r.getHasPrevSection() : true;
        const hasNextSection = typeof r.getHasNextSection === "function" ? await r.getHasNextSection() : true;
        const sectionIndex = typeof this.navHUD?.lastRelocateDetail?.sectionIndex === 'number'
            ? this.navHUD.lastRelocateDetail.sectionIndex
            : (typeof this.navHUD?.lastRelocateDetail?.index === 'number'
                ? this.navHUD.lastRelocateDetail.index
                : (typeof r.currentIndex === 'number' ? r.currentIndex : null));
        const sectionHref = typeof sectionIndex === 'number'
            ? (typeof this.view?.renderer?.tocItem?.href === 'string'
                ? this.view.renderer.tocItem.href
                : (typeof this.view?.book?.sections?.[sectionIndex]?.id === 'string'
                    ? this.view.book.sections[sectionIndex].id
                    : ''))
            : (typeof this.view?.renderer?.tocItem?.href === 'string'
                ? this.view.renderer.tocItem.href
                : '');
        const isMetadataSection = isLikelyMetadataSectionHref(sectionHref);
        const pageCountFromCache = typeof sectionIndex === 'number' && this.navHUD?.sectionPageCounts instanceof Map
            ? this.navHUD.sectionPageCounts.get(sectionIndex)
            : null;
        const pageCount = typeof pageCountFromCache === 'number' && pageCountFromCache > 0
            ? pageCountFromCache
            : (typeof this.navHUD?.rendererPageSnapshot?.total === 'number' && this.navHUD.rendererPageSnapshot.total > 0
                ? this.navHUD.rendererPageSnapshot.total
                : (typeof this.navHUD?.lastRelocateDetail?.pageCount === 'number'
                    ? this.navHUD.lastRelocateDetail.pageCount
                    : null));
        const isSinglePageMetadataSection = isMetadataSection && pageCount === 1;
        const finishLabel = isSinglePageMetadataSection ? 'Mark Read' : 'Finish Chapter';
        const isRestartHiddenForMiddlePageWhileNavHidden =
            !!this.markedAsFinished
            && !!this.navHUD?.hideNavigationDueToScroll
            && !atSectionStart
            && !atSectionEnd;
        const completionAction = this.markedAsFinished
            ? (isRestartHiddenForMiddlePageWhileNavHidden
                ? null
                : {
                    type: 'restart',
                    label: 'Start Over Chapter',
                    tone: 'restart',
                })
            : (atSectionEnd && !hasNextSection
                ? {
                    type: 'finish',
                    label: finishLabel,
                    tone: 'finish',
                }
                : null);
        this.completionAction = completionAction;
        if (!completionAction) {
            this.completionActionBusy = false;
        }

        this.#show(this.buttons.prev, atSectionStart && hasPrevSection);

        if (atSectionEnd && hasNextSection) {
            this.#show(this.buttons.next, true);
        } else {
            this.#show(this.buttons.next, false);
        }
        const showingCompletion = !!completionAction;
        this.showingCompletionButtons = showingCompletion;
        this.navHUD?._toggleCompletionStack?.(false);

        // RTL/LTR logic for disabling/hiding side chevrons
        const btnScrollLeft = document.getElementById('btn-scroll-left');
        const btnScrollRight = document.getElementById('btn-scroll-right');
        if (btnScrollLeft && btnScrollRight) {
            const compactSheetSidePaginationDisabled = isCompactNavigationSheetSidePaginationDisabled();
            if (this.isRTL) {
                // In RTL, left chevron = go forward, right chevron = go backward
                // Disable left at end, right at start
                btnScrollLeft.disabled = compactSheetSidePaginationDisabled || (atSectionEnd && !hasNextSection);
                btnScrollRight.disabled = compactSheetSidePaginationDisabled || (atSectionStart && !hasPrevSection);
            } else {
                // LTR, left chevron = backward, right chevron = forward
                // Disable left at start, right at end
                btnScrollLeft.disabled = compactSheetSidePaginationDisabled || (atSectionStart && !hasPrevSection);
                btnScrollRight.disabled = compactSheetSidePaginationDisabled || (atSectionEnd && !hasNextSection);
            }
        }

        this.navHUD?.setNavContext({
            atSectionStart,
            atSectionEnd,
            hasPrevSection,
            hasNextSection,
            showingFinish: false,
            showingRestart: false,
            sections: this.view?.book?.sections ?? [],
        });
        if (this.navHUD?.hideNavigationDueToScroll) {
            this.navHUD.setHideNavigationDueToScroll(true, 'reader.updateNavButtons.reapply', {
                atSectionStart,
                atSectionEnd,
                hasPrevSection,
                hasNextSection,
            });
        }
        this.#schedulePageTrackingSync('nav-buttons', null, 1);
    }
    async #handleKeydown(event) {
        const k = event.key;
        const renderer = this.view?.renderer;
        if (!renderer) return;
        const isRTL = this.isRTL;

        if (k === 'ArrowLeft' || k === 'h') {
            if (isRTL && await renderer.atEnd()) {
                this.buttons.next.click();
            } else if (!isRTL && await renderer.atStart()) {
                this.buttons.prev.click();
            } else {
                await this.#runPageTurn({
                    stage: 'pageTurn.keydown',
                    markInputSource: `pageTurn.keydown.${k}`,
                    details: {
                        key: k,
                        method: 'goLeft',
                        isRTL,
                    },
                    move: async () => await this.view.goLeft(),
                });
            }
        } else if (k === 'ArrowRight' || k === 'l') {
            if (isRTL && await renderer.atStart()) {
                this.buttons.prev.click();
            } else if (!isRTL && await renderer.atEnd()) {
                this.buttons.next.click();
            } else {
                await this.#runPageTurn({
                    stage: 'pageTurn.keydown',
                    markInputSource: `pageTurn.keydown.${k}`,
                    details: {
                        key: k,
                        method: 'goRight',
                        isRTL,
                    },
                    move: async () => await this.view.goRight(),
                });
            }
        }
    }
    async handlePhysicalArrowKey(direction) {
        const key = direction === 'left'
            ? 'ArrowLeft'
            : direction === 'right'
                ? 'ArrowRight'
                : null;
        if (!key) return false;
        await this.#handleKeydown({ key });
        return true;
    }
    #lookupContentWindows() {
        const contents = this.view?.renderer?.getContents?.() || [];
        return contents
            .map((content) => content?.doc?.defaultView || content?.document?.defaultView || null)
            .filter((view) => view && !isCacheWarmerDocument(view.document));
    }
    #lookupNavigationDocuments() {
        return this.#lookupContentWindows().map((view) => view.document).filter(isDocumentLike);
    }
    #lookupNavigationVisibleSegmentSummary(doc, result) {
        const visibleSegments = Array.isArray(result?.visibleSegments)
            ? result.visibleSegments
            : [];
        const firstID = visibleSegments[0]?.node?.id ?? null;
        const lastID = visibleSegments[visibleSegments.length - 1]?.node?.id ?? null;
        const href = doc?.location?.href ?? null;
        return {
            href,
            visibleSegmentCount: visibleSegments.length,
            firstVisibleSegmentID: firstID,
            lastVisibleSegmentID: lastID,
            signature: `${href ?? ''}|${visibleSegments.length}|${firstID ?? ''}|${lastID ?? ''}`,
        };
    }
    #lookupNavigationVisibleSegmentSignatureFromRefreshResults(refreshResults = []) {
        if (!Array.isArray(refreshResults) || refreshResults.length === 0) {
            return '';
        }
        return refreshResults
            .map((result) => result?.signature ?? `${result?.href ?? ''}|${result?.visibleSegmentCount ?? 0}|${result?.firstVisibleSegmentID ?? ''}|${result?.lastVisibleSegmentID ?? ''}`)
            .join('||');
    }
    #lookupNavigationVisibleSegmentSnapshot(reason = 'lookup-navigation.visible-snapshot') {
        const docs = this.#lookupNavigationDocuments();
        const refreshResults = [];
        for (const doc of docs) {
            const visibleRange = this.#visibleRangeForDocument(doc);
            const result = this.#visiblePageSegmentResult(doc, visibleRange, reason, {
                postLookupTargets: false,
                prepareLookupIndex: false,
                hydrateStatuses: false,
            });
            refreshResults.push({
                ...this.#lookupNavigationVisibleSegmentSummary(doc, result),
                fontStatus: doc?.fonts?.status ?? null,
            });
        }
        return {
            reason,
            refreshResults,
            signature: this.#lookupNavigationVisibleSegmentSignatureFromRefreshResults(refreshResults),
        };
    }
    #settleAfterLookupPageTurn(reason = 'lookup-navigation.page-turn-settled') {
        const docs = this.#lookupNavigationDocuments();
        const refreshResults = [];
        for (const doc of docs) {
            const visibleRange = this.#visibleRangeForDocument(doc);
            this.visiblePageSegmentSnapshot = null;
            const result = this.#visiblePageSegmentResult(doc, visibleRange, reason);
            const summary = this.#lookupNavigationVisibleSegmentSummary(doc, result);
            refreshResults.push({
                ...summary,
                fontStatus: doc?.fonts?.status ?? null,
            });
        }
        return {
            reason,
            refreshResults,
            signature: this.#lookupNavigationVisibleSegmentSignatureFromRefreshResults(refreshResults),
        };
    }
    #refreshLookupNavigationVisibleTargets(reason = 'lookup-navigation.visible-target-readiness') {
        const docs = this.#lookupNavigationDocuments();
        const results = [];
        for (const doc of docs) {
            const visibleRange = this.#visibleRangeForDocument(doc);
            this.visiblePageSegmentSnapshot = null;
            const result = this.#visiblePageSegmentResult(doc, visibleRange, reason, { postIfCached: true });
            const summary = this.#lookupNavigationVisibleSegmentSummary(doc, result);
            results.push({
                ...summary,
                fontStatus: doc?.fonts?.status ?? null,
            });
        }
        return results;
    }
    async #refreshLookupNavigationVisibleTargetsAfterFonts(reason = 'lookup-navigation.visible-target-readiness.fonts') {
        const docs = this.#lookupNavigationDocuments();
        const pendingFontDocs = docs.filter((doc) => doc?.fonts?.status === 'loading' && doc?.fonts?.ready?.then);
        if (pendingFontDocs.length === 0) {
            return { advanced: false, reason: 'fonts-ready-or-unavailable', refreshResults: [] };
        }
        await Promise.all(
            pendingFontDocs.map((doc) => Promise.resolve(doc.fonts.ready).catch(() => null))
        );
        return {
            advanced: true,
            reason: 'fonts-ready',
            refreshResults: this.#refreshLookupNavigationVisibleTargets(reason),
        };
    }
    async #refreshLookupNavigationVisibleTargetsAfterRendererSettle(reason = 'lookup-navigation.visible-target-readiness.renderer') {
        const renderer = this.view?.renderer;
        if (!renderer || typeof renderer.renderIfContainerSizeChanged !== 'function') {
            return { advanced: false, reason: 'renderer-unavailable', refreshResults: [] };
        }
        const renderResult = await renderer.renderIfContainerSizeChanged(reason);
        if (renderResult?.rendered !== true) {
            return { advanced: false, reason: renderResult?.reason ?? 'renderer-did-not-render', renderResult, refreshResults: [] };
        }
        return {
            advanced: true,
            reason: 'renderer-rendered',
            renderResult,
            refreshResults: this.#refreshLookupNavigationVisibleTargets(reason),
        };
    }
    refreshLookupNavigationVisibleTargetsForRelocate(reason = 'lookup-navigation.relocate') {
        return this.#refreshLookupNavigationVisibleTargets(reason);
    }
    async #visibleLookupNavigationReadiness(request) {
        const kind = request?.kind === 'sentence' || request?.kind === 'section' ? request.kind : 'word';
        const direction = request?.direction === 'previous' ? 'previous' : 'next';
        const functionName = 'manabi_visibleLookupNavigationReadiness';
        const contentWindows = this.#lookupContentWindows()
            .filter((view) => typeof view?.[functionName] === 'function');
        const orderedContentWindows = direction === 'previous'
            ? contentWindows.slice().reverse()
            : contentWindows;
        if (orderedContentWindows.length === 0) {
            return {
                ready: false,
                failureReason: 'missingVisibleLookupReadiness',
                kind,
                direction,
                contentWindowAttempts: [],
            };
        }
        const attempts = [];
        for (const contentWindow of orderedContentWindows) {
            let result = null;
            try {
                result = contentWindow[functionName]({
                    ...(request && typeof request === 'object' ? request : {}),
                    kind,
                    direction,
                });
            } catch (error) {
                result = {
                    ready: false,
                    failureReason: 'visibleLookupReadinessError',
                    error: error?.message || String(error),
                };
            }
            const attempt = {
                windowURL: contentWindow.location?.href ?? null,
                ready: result?.ready === true,
                failureReason: result?.failureReason ?? null,
                targetElementID: result?.target?.id ?? null,
                visibleSegmentCount: result?.visibleSegmentCount ?? null,
                visibleElementIDCount: result?.visibleElementIDCount ?? null,
                preparedVisibleElementIDCount: result?.preparedVisibleElementIDCount ?? null,
                hitTargetCount: result?.hitTargetCount ?? null,
            };
            attempts.push(attempt);
            if (result?.ready === true) {
                return {
                    ...(result ?? {}),
                    ready: true,
                    kind,
                    direction,
                    contentWindowURL: contentWindow.location?.href ?? null,
                    contentWindowAttempts: attempts,
                };
            }
        }
        return {
            ready: false,
            failureReason: 'noVisibleTargetAfterPageTurn',
            kind,
            direction,
            contentWindowAttempts: attempts,
        };
    }
    async #waitForVisibleLookupNavigationReadiness(request) {
        const startedAt = performance.now();
        const samples = [];
        const initialRefreshResults = this.#refreshLookupNavigationVisibleTargets('lookup-navigation.visible-target-readiness');
        let readiness = await this.#visibleLookupNavigationReadiness(request);
        samples.push({
            attempt: 0,
            elapsedMs: Math.round(performance.now() - startedAt),
            ready: readiness?.ready === true,
            failureReason: readiness?.failureReason ?? null,
            targetElementID: readiness?.target?.id ?? null,
            refreshResults: initialRefreshResults,
            contentWindowAttempts: readiness?.contentWindowAttempts ?? [],
        });
        if (readiness?.ready !== true) {
            const fontResult = await this.#refreshLookupNavigationVisibleTargetsAfterFonts('lookup-navigation.visible-target-readiness.fonts');
            if (fontResult.advanced === true) {
                readiness = await this.#visibleLookupNavigationReadiness(request);
                samples.push({
                    attempt: samples.length,
                    elapsedMs: Math.round(performance.now() - startedAt),
                    ready: readiness?.ready === true,
                    failureReason: readiness?.failureReason ?? null,
                    targetElementID: readiness?.target?.id ?? null,
                    refreshStage: fontResult.reason,
                    refreshResults: fontResult.refreshResults,
                    contentWindowAttempts: readiness?.contentWindowAttempts ?? [],
                });
            } else {
                samples.push({
                    attempt: samples.length,
                    elapsedMs: Math.round(performance.now() - startedAt),
                    ready: false,
                    failureReason: readiness?.failureReason ?? null,
                    targetElementID: readiness?.target?.id ?? null,
                    refreshStage: fontResult.reason,
                    contentWindowAttempts: readiness?.contentWindowAttempts ?? [],
                });
            }
        }
        if (readiness?.ready !== true) {
            const rendererResult = await this.#refreshLookupNavigationVisibleTargetsAfterRendererSettle('lookup-navigation.visible-target-readiness.renderer');
            if (rendererResult.advanced === true) {
                readiness = await this.#visibleLookupNavigationReadiness(request);
                samples.push({
                    attempt: samples.length,
                    elapsedMs: Math.round(performance.now() - startedAt),
                    ready: readiness?.ready === true,
                    failureReason: readiness?.failureReason ?? null,
                    targetElementID: readiness?.target?.id ?? null,
                    refreshStage: rendererResult.reason,
                    refreshResults: rendererResult.refreshResults,
                    contentWindowAttempts: readiness?.contentWindowAttempts ?? [],
                });
            } else {
                samples.push({
                    attempt: samples.length,
                    elapsedMs: Math.round(performance.now() - startedAt),
                    ready: false,
                    failureReason: readiness?.failureReason ?? null,
                    targetElementID: readiness?.target?.id ?? null,
                    refreshStage: rendererResult.reason,
                    renderResult: rendererResult.renderResult ?? null,
                    contentWindowAttempts: readiness?.contentWindowAttempts ?? [],
                });
            }
        }
        return {
            readiness,
            samples,
        };
    }
    async #openVisibleLookupTargetAfterPageTurnWhenReady(request) {
        const readinessResult = await this.#waitForVisibleLookupNavigationReadiness(request);
        const readiness = readinessResult?.readiness ?? null;
        if (readiness?.ready !== true) {
            return {
                opened: false,
                failureReason: readiness?.failureReason ?? 'noVisibleTargetAfterPageTurn',
                kind: request?.kind === 'sentence' || request?.kind === 'section' ? request.kind : 'word',
                direction: request?.direction === 'previous' ? 'previous' : 'next',
                visibleLookupReadiness: readiness,
                visibleLookupReadinessSamples: readinessResult?.samples ?? [],
            };
        }
        const refreshResults = this.#refreshLookupNavigationVisibleTargets('lookup-navigation.visible-target-open');
        const result = await this.#openVisibleLookupTargetAfterPageTurn(request);
        if (result && typeof result === 'object') {
            result.visibleLookupReadiness = readiness;
            result.visibleLookupReadinessSamples = readinessResult?.samples ?? [];
            result.visibleLookupOpenRefreshResults = refreshResults;
        }
        return result;
    }
    #lookupNavigationPositionSnapshot() {
        const renderer = this.view?.renderer ?? null;
        const relocateDetail = this.navHUD?.lastRelocateDetail ?? null;
        return {
            sectionIndex: getPrimaryRendererContentIndex(renderer),
            rendererCurrentIndex: typeof renderer?.currentIndex === 'number' ? renderer.currentIndex : null,
            pageCurrent: typeof this.navHUD?.rendererPageSnapshot?.current === 'number' ? this.navHUD.rendererPageSnapshot.current : null,
            pageTotal: typeof this.navHUD?.rendererPageSnapshot?.total === 'number' ? this.navHUD.rendererPageSnapshot.total : null,
            fraction: typeof relocateDetail?.fraction === 'number' && Number.isFinite(relocateDetail.fraction)
                ? safeRound(relocateDetail.fraction, 6)
                : null,
        };
    }
    #lookupNavigationPositionChanged(before, after) {
        if (!before || !after) return false;
        return before.sectionIndex !== after.sectionIndex
            || before.rendererCurrentIndex !== after.rendererCurrentIndex
            || before.pageCurrent !== after.pageCurrent
            || before.pageTotal !== after.pageTotal
            || before.fraction !== after.fraction;
    }
    async #openVisibleLookupTargetAfterPageTurn(request) {
        const kind = request?.kind === 'sentence' || request?.kind === 'section' ? request.kind : 'word';
        const direction = request?.direction === 'previous' ? 'previous' : 'next';
        const functionName = 'manabi_openVisibleLookupTargetAfterPageTurn';
        const contentWindows = this.#lookupContentWindows()
            .filter((view) => typeof view?.[functionName] === 'function');
        const orderedContentWindows = direction === 'previous'
            ? contentWindows.slice().reverse()
            : contentWindows;
        if (orderedContentWindows.length === 0) {
            return {
                opened: false,
                failureReason: 'missingVisibleLookupFallback',
                kind,
                direction,
            };
        }
        const attempts = [];
        for (const contentWindow of orderedContentWindows) {
            let result = null;
            try {
                result = await contentWindow[functionName]({
                    ...(request && typeof request === 'object' ? request : {}),
                    kind,
                    direction,
                    allowEbookPageTurn: false,
                });
            } catch (error) {
                result = {
                    opened: false,
                    failureReason: 'visibleLookupFallbackError',
                    error: error?.message || String(error),
                };
            }
            attempts.push({
                windowURL: contentWindow.location?.href ?? null,
                opened: result?.opened === true,
                failureReason: result?.failureReason ?? null,
                targetElementID: result?.target?.id ?? null,
            });
            if (result?.opened === true) {
                result.contentWindowURL = contentWindow.location?.href ?? null;
                result.contentWindowAttempts = attempts;
                return result;
            }
            if (result?.failureReason !== 'noVisibleTargetAfterPageTurn') {
                return {
                    ...(result ?? {}),
                    opened: false,
                    kind,
                    direction,
                    contentWindowURL: contentWindow.location?.href ?? null,
                    contentWindowAttempts: attempts,
                };
            }
        }
        return {
            opened: false,
            failureReason: 'noVisibleTargetAfterPageTurn',
            kind,
            direction,
            contentWindowAttempts: attempts,
        };
    }
    async #turnLookupNavigationPage(direction) {
        const renderer = this.view?.renderer;
        if (!renderer || !this.view) {
            return {
                moved: false,
                failureReason: 'missingRenderer',
            };
        }
        const normalizedDirection = direction === 'previous' ? 'previous' : 'next';
        const atStart = await renderer.atStart?.();
        const atEnd = await renderer.atEnd?.();
        const beforePosition = this.#lookupNavigationPositionSnapshot();
        if (normalizedDirection === 'next') {
            if (atEnd === true) {
                this.#clearVisiblePageReadChrome('lookup-navigation-page-turn-start');
                this.#applyLogicalPageTurnNavigationVisibility('forward', 'lookup-navigation.next-section');
                await renderer.nextSection?.();
                return { moved: true, mode: 'nextSection' };
            }
            this.#clearVisiblePageReadChrome('lookup-navigation-page-turn-start');
            this.#applyLogicalPageTurnNavigationVisibility('forward', 'lookup-navigation.page');
            if (this.isRTL) {
                await this.view.goLeft();
                return { moved: true, mode: 'goLeft' };
            }
            await this.view.goRight();
            return { moved: true, mode: 'goRight' };
        }
        if (atStart === true) {
            this.#clearVisiblePageReadChrome('lookup-navigation-page-turn-start');
            this.#applyLogicalPageTurnNavigationVisibility('backward', 'lookup-navigation.previous-section');
            await renderer.prevSection?.();
            return { moved: true, mode: 'prevSection' };
        }
        this.#clearVisiblePageReadChrome('lookup-navigation-page-turn-start');
        this.#applyLogicalPageTurnNavigationVisibility('backward', 'lookup-navigation.page');
        if (this.isRTL) {
            await this.view.goRight();
            return { moved: true, mode: 'goRight' };
        }
        await this.view.goLeft();
        return { moved: true, mode: 'goLeft' };
    }
    async performLookupNavigationPageTurn(request = {}) {
        const token = (this.lookupNavigationPageTurnToken ?? 0) + 1;
        this.lookupNavigationPageTurnToken = token;
        this.lookupNavigationPageTurnActive = true;
        const kind = request?.kind === 'sentence' || request?.kind === 'section' ? request.kind : 'word';
        const direction = request?.direction === 'previous' ? 'previous' : 'next';
        const maxPageTurns = Math.max(1, Math.min(12, Number.isFinite(request?.maxPageTurns) ? Math.round(request.maxPageTurns) : 8));
        const startedAt = performance.now();
        const attempts = [];
        try {
        for (let pageTurnIndex = 0; pageTurnIndex < maxPageTurns; pageTurnIndex += 1) {
            if (this.lookupNavigationPageTurnToken !== token) {
                return {
                    opened: false,
                    failureReason: 'superseded',
                    kind,
                    direction,
                    elapsedMs: Math.round(performance.now() - startedAt),
                    attempts,
                };
            }
            let turnResult = null;
            const positionBeforeTurn = this.#lookupNavigationPositionSnapshot();
            const visiblePositionBeforeTurn = this.#lookupNavigationVisibleSegmentSnapshot('lookup-navigation.page-turn-before');
            const displaySettledSequenceBeforeTurn = this.displaySettledSequence;
            try {
                turnResult = await this.#turnLookupNavigationPage(direction);
            } catch (error) {
                turnResult = {
                    moved: false,
                    failureReason: 'pageTurnError',
                    error: error?.message || String(error),
                };
            }
            if (turnResult) {
                turnResult.positionBefore = positionBeforeTurn;
            }
            if (turnResult?.moved === false) {
                attempts.push({
                    pageTurnIndex,
                    turnResult,
                    visibleTargetOpened: false,
                    visibleTargetFailureReason: turnResult?.failureReason ?? 'pageTurnDidNotMove',
                });
                break;
            }
            let positionAfterTurn = this.#lookupNavigationPositionSnapshot();
            const crossedSection =
                positionBeforeTurn?.sectionIndex !== positionAfterTurn?.sectionIndex
                || positionBeforeTurn?.rendererCurrentIndex !== positionAfterTurn?.rendererCurrentIndex;
            if (
                crossedSection
                && this.displaySettledSequence === displaySettledSequenceBeforeTurn
            ) {
                turnResult.displaySettled = await this.waitForNextDisplaySettled('lookup-navigation.page-turn');
                positionAfterTurn = this.#lookupNavigationPositionSnapshot();
            }
            const navigationSettledResult = this.#settleAfterLookupPageTurn('lookup-navigation.page-turn-settled');
            const visiblePositionAfterTurn = {
                reason: navigationSettledResult.reason,
                refreshResults: navigationSettledResult.refreshResults,
                signature: navigationSettledResult.signature,
            };
            const visiblePositionChanged =
                (visiblePositionBeforeTurn.signature || '') !== (visiblePositionAfterTurn.signature || '');
            const positionChanged =
                this.#lookupNavigationPositionChanged(positionBeforeTurn, positionAfterTurn)
                || visiblePositionChanged;
            if (turnResult) {
                turnResult.positionAfter = positionAfterTurn;
                turnResult.positionChanged = positionChanged;
                turnResult.visiblePositionBefore = visiblePositionBeforeTurn;
                turnResult.visiblePositionAfter = visiblePositionAfterTurn;
                turnResult.visiblePositionChanged = visiblePositionChanged;
                turnResult.crossedSection = crossedSection;
                turnResult.navigationSettled = navigationSettledResult;
            }
            if (!positionChanged) {
                attempts.push({
                    pageTurnIndex,
                    turnResult,
                    visibleTargetOpened: false,
                    visibleTargetFailureReason: 'pageTurnDidNotMove',
                });
                break;
            }
            const attempt = {
                pageTurnIndex,
                turnResult,
                visibleTargetOpened: false,
                visibleTargetFailureReason: null,
            };
            attempts.push(attempt);
            let visibleTargetResult = null;
            try {
                visibleTargetResult = await this.#openVisibleLookupTargetAfterPageTurnWhenReady({
                    ...(request && typeof request === 'object' ? request : {}),
                    kind,
                    direction,
                });
            } catch (error) {
                visibleTargetResult = {
                    opened: false,
                    failureReason: 'visibleTargetError',
                    error: error?.message || String(error),
                };
            }
            attempt.visibleTargetOpened = visibleTargetResult?.opened === true;
            attempt.visibleTargetFailureReason = visibleTargetResult?.failureReason ?? null;
            if (visibleTargetResult?.opened === true) {
                return {
                    opened: true,
                    pageTurnRequested: true,
                    kind,
                    direction,
                    pageTurnIndex,
                    visibleTargetResult,
                    attempts,
                    elapsedMs: Math.round(performance.now() - startedAt),
                };
            }
            if (visibleTargetResult?.failureReason !== 'noVisibleTargetAfterPageTurn') {
                break;
            }
        }
        return {
            opened: false,
            failureReason: 'pageTurnLookupTargetNotFound',
            kind,
            direction,
            attempts,
            elapsedMs: Math.round(performance.now() - startedAt),
        };
        } finally {
            if (this.lookupNavigationPageTurnToken === token) {
                this.lookupNavigationPageTurnActive = false;
            }
        }
    }
    #installVisibleRendererGoToGuard() {
        const renderer = this.view?.renderer;
        if (!renderer || renderer.__manabiVisibleGoToGuardInstalled) return;
        const originalGoTo = renderer.goTo;
        if (typeof originalGoTo !== 'function') return;
        const reader = this;
        renderer.goTo = function guardedVisibleRendererGoTo(target, ...args) {
            const targetIndex = typeof target?.index === 'number' ? Math.max(0, Math.round(target.index)) : null;
            const currentIndex = getPrimaryRendererContentIndex(renderer);
            const currentPage = reader.navHUD?.rendererPageSnapshot?.current ?? null;
            const totalPages = reader.navHUD?.rendererPageSnapshot?.total ?? null;
            const targetAnchor = typeof target?.anchor === 'number' && Number.isFinite(target.anchor)
                ? Math.max(0, Math.min(1, target.anchor))
                : null;
            const targetPage = typeof targetAnchor === 'number'
                && typeof totalPages === 'number'
                && totalPages > 1
                ? Math.max(1, Math.min(totalPages, Math.round(targetAnchor * (totalPages - 1)) + 1))
                : null;
            const sameIndex = typeof targetIndex === 'number'
                && typeof currentIndex === 'number'
                && targetIndex === currentIndex;
            const sameVisiblePage = sameIndex
                && (
                    targetAnchor === null
                    || (
                        typeof targetPage === 'number'
                        && typeof currentPage === 'number'
                        && targetPage === currentPage
                    )
                );
            if (sameVisiblePage) {
                return Promise.resolve();
            }
            return originalGoTo.call(this, target, ...args);
        };
        renderer.__manabiVisibleGoToGuardInstalled = true;
    }
    #resetInitialDisplaySettledPromise() {
        this.initialDisplaySettled = false;
        this.initialDisplaySettledPromise = new Promise((resolve) => {
            this.initialDisplaySettledResolve = resolve;
        });
    }
    #resolveInitialDisplaySettled(reason = 'unspecified') {
        if (this.initialDisplaySettled) return;
        this.initialDisplaySettled = true;
        const resolve = this.initialDisplaySettledResolve;
        this.initialDisplaySettledResolve = null;
        resolve?.({
            reason,
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
            hasReaderContent: !!document.querySelector?.('foliate-view'),
        });
    }
    async waitForInitialDisplaySettled(reason = 'unspecified', {
        timeoutMs = null,
    } = {}) {
        if (this.initialDisplaySettled) {
            return {
                settled: true,
                reason: 'already-settled',
            };
        }
        if (!this.initialDisplaySettledPromise) {
            this.#resetInitialDisplaySettledPromise();
        }
        const startedAt = performanceNowMs();
        let timeoutHandle = null;
        try {
            const result = await (
                Number.isFinite(timeoutMs) && timeoutMs > 0
                    ? Promise.race([
                        this.initialDisplaySettledPromise,
                        new Promise((_, reject) => {
                            timeoutHandle = setTimeout(() => {
                                reject(new Error(`Timed out after ${timeoutMs}ms`));
                            }, timeoutMs);
                        }),
                    ])
                    : this.initialDisplaySettledPromise
            );
            return {
                settled: true,
                ...result,
            };
        } catch (error) {
            throw error;
        } finally {
            if (timeoutHandle !== null) {
                clearTimeout(timeoutHandle);
            }
        }
    }
    #settleInitialDisplayFromVisibleContent(reason = 'unspecified') {
        if (this.initialDisplaySettled) {
            return {
                settled: true,
                reason: 'already-settled',
            };
        }
        const renderer = this.view?.renderer ?? null;
        const contents = renderer?.getContents?.() || [];
        const currentIndex = getPrimaryRendererContentIndex(renderer);
        const activeContents = typeof currentIndex === 'number'
            ? contents.filter((content) => typeof content?.index !== 'number' || content.index === currentIndex)
            : contents;
        let observedSegmentCount = 0;
        let visibleSegmentCount = 0;
        for (const content of activeContents) {
            const doc = content?.doc || content?.document || null;
            if (!isDocumentLike(doc)) { continue; }
            const visibleRange = this.#visibleRangeForDocument(doc);
            const visibleSegmentsResult = this.#renderableContentProbeResult(
                doc,
                visibleRange,
                `initialDisplay.visible-content:${reason}`
            );
            const visibleContentState = visibleRenderableContentStateForDocument(doc, visibleSegmentsResult);
            observedSegmentCount += visibleContentState.observedSegmentCount;
            visibleSegmentCount += visibleContentState.visibleSegmentCount;
            if (visibleContentState.hasRenderableContent === true) {
                const clearReason = `initialDisplay.visible-content:${reason}`;
                // Visible geometry is not proof that WebKit has painted the final
                // paginated result. Keep the loading cover until #onDidDisplay has
                // completed its post-settle frame boundary; otherwise long style and
                // column-layout passes are exposed as a blank page.
                manabiTimelineMark('initialDisplay.visibleContent.loadingRetained', {
                    reason,
                    bodyLoading: document.body?.classList?.contains?.('loading') === true,
                    bodyLoadingVisual: document.body?.classList?.contains?.('loading-visual') === true,
                    visibleSegmentCount,
                    observedSegmentCount,
                });
                markReaderRenderReady(clearReason);
                globalThis.__manabiPostReaderDocStateEvent?.(clearReason);
                this.#resolveInitialDisplaySettled(clearReason);
                this.#resolveDisplaySettledWaiters(clearReason);
                try {
                    globalThis.__manabiFinishEPUBLoadWatchdogs?.(clearReason);
                } catch (_error) {}
                return {
                    settled: true,
                    reason: clearReason,
                    visibleSegmentCount,
                    observedSegmentCount,
                    hasVisibleSingleMedia: visibleContentState.hasVisibleSingleMedia === true,
                };
            }
        }
        return {
            settled: false,
            reason: 'no-visible-text',
            visibleSegmentCount,
            observedSegmentCount,
        };
    }
    settleInitialDisplayFromVisibleContent(reason = 'unspecified') {
        return this.#settleInitialDisplayFromVisibleContent(reason);
    }
    #resolveDisplaySettledWaiters(reason = 'unspecified') {
        this.displaySettledSequence += 1;
        const waiters = this.displaySettledWaiters.splice(0);
        if (!waiters.length) return;
        const result = {
            reason,
            sequence: this.displaySettledSequence,
            bodyLoading: !!document.body?.classList?.contains?.('loading'),
            hasReaderContent: !!document.querySelector?.('foliate-view'),
            renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
        };
        waiters.forEach((waiter) => {
            if (typeof waiter === 'function') {
                waiter(result);
            } else {
                waiter?.resolve?.(result);
            }
        });
    }
    resolveDisplaySettledWaiters(reason = 'unspecified') {
        this.#resolveDisplaySettledWaiters(reason);
    }
    clearLoadingForRelocatedVisibleContent(reason = 'unspecified', visibleSegmentsResult = null) {
        if (!document.body?.classList?.contains?.('loading')) {
            return { cleared: false, reason: 'not-loading' };
        }
        const content = this.view?.renderer?.getContents?.()?.[0] ?? null;
        const doc = content?.doc ?? content?.document ?? null;
        if (!isDocumentLike(doc)) {
            return { cleared: false, reason: 'missing-document' };
        }
        if (!visibleSegmentsResult) {
            const visibleRange = this.#visibleRangeForDocument(doc);
            visibleSegmentsResult = this.#visiblePageSegmentResult(
                doc,
                visibleRange,
                `relocate.visible-content:${reason}`,
                {
                    postIfCached: true,
                    includeClientRects: true,
                    postLookupTargets: true,
                    prepareLookupIndex: true,
                    hydrateStatuses: true,
                }
            );
        }
        const visibleContentState = visibleRenderableContentStateForDocument(doc, visibleSegmentsResult);
        if (visibleContentState.hasRenderableContent !== true) {
            return {
                cleared: false,
                reason: 'no-visible-text',
                visibleSegmentCount: visibleContentState.visibleSegmentCount,
                observedSegmentCount: visibleContentState.observedSegmentCount,
                hasVisibleSingleMedia: visibleContentState.hasVisibleSingleMedia === true,
            };
        }
        const clearReason = `relocate.visible-content:${reason}`;
        this.setLoadingIndicator(false, clearReason);
        markReaderRenderReady(clearReason);
        globalThis.__manabiPostReaderDocStateEvent?.(clearReason);
        this.#resolveInitialDisplaySettled(clearReason);
        this.#resolveDisplaySettledWaiters(clearReason);
        try {
            globalThis.__manabiFinishEPUBLoadWatchdogs?.(clearReason);
        } catch (_error) {}
        return {
            cleared: true,
            reason: clearReason,
            visibleSegmentCount: visibleContentState.visibleSegmentCount,
            observedSegmentCount: visibleContentState.observedSegmentCount,
            hasVisibleSingleMedia: visibleContentState.hasVisibleSingleMedia === true,
        };
    }
    async waitForNextDisplaySettled(reason = 'unspecified', {
        timeoutMs = null,
    } = {}) {
        const startedAt = performanceNowMs();
        const startedSequence = this.displaySettledSequence;
        let timeoutHandle = null;
        let waiter = null;
        try {
            const result = await new Promise((resolve, reject) => {
                waiter = { resolve, reject };
                this.displaySettledWaiters.push(waiter);
                if (Number.isFinite(timeoutMs) && timeoutMs > 0) {
                    timeoutHandle = setTimeout(() => {
                        this.displaySettledWaiters = this.displaySettledWaiters.filter((item) => item !== waiter);
                        reject(new Error(`Timed out after ${timeoutMs}ms`));
                    }, timeoutMs);
                }
            });
            return result;
        } catch (error) {
            throw error;
        } finally {
            clearTimeout(timeoutHandle);
        }
    }
    #onGoTo(event = {}) {
        const goToDetail = event?.detail ?? event ?? {};
        const willLoadNewIndex = goToDetail.willLoadNewIndex === true;
        if (!willLoadNewIndex) {
            this.sameIndexGoToDidDisplaySkips = Math.max(1, this.sameIndexGoToDidDisplaySkips || 0);
            return;
        }
        this.#clearVisiblePageReadChrome('goTo');
        this.#invalidateVisiblePageSegmentSnapshot('renderer.goTo');
        requestLookupCloseForPageMotion('renderer.goTo', {
            willLoadNewIndex: true,
        });
        this.setLoadingIndicator(true, 'renderer.goTo');
    }
    async #onDidDisplay({}) {
        const didDisplayStartedAt = performanceNowMs();
        const navVisibilityBefore = captureNavVisibilityState();
        const shouldSkipSameIndexDidDisplay =
            (this.sameIndexGoToDidDisplaySkips || 0) > 0
            && !document.body?.classList?.contains?.('loading');
        if (shouldSkipSameIndexDidDisplay) {
            this.sameIndexGoToDidDisplaySkips = Math.max(0, (this.sameIndexGoToDidDisplaySkips || 0) - 1);
            this.#resolveInitialDisplaySettled('didDisplay.skipSameIndex');
            return;
        }
        this.#postBookInsetSnapshot('didDisplay.begin', {
            beforeNavigationVisibility: navVisibilityBefore,
        });
        let initialSettleResult = null;
        let postFrameSettleResult = null;
        try {
            applyStoredChromeInsets('reader.didDisplay');
            initialSettleResult = await this.#settleInitialPaginatorLayout('did-display.pre-clear', {
                allowWhileLoading: true,
            });
            this.#postBookInsetSnapshot('didDisplay.after-initial-settle', {
                initialSettleResult,
            });
            const shouldRunPostFrameSettle =
                MANABI_ENABLE_DID_DISPLAY_POST_FRAME_SETTLE
                && (
                initialSettleResult?.rendered === true
                || initialSettleResult?.reason === 'error'
                );
            if (shouldRunPostFrameSettle) {
                await this.#waitForAnimationFrames(2);
                this.#postBookInsetSnapshot('didDisplay.after-two-frames-before-force', {
                    initialSettleResult,
                });
                postFrameSettleResult = await this.#settleInitialPaginatorLayout('did-display.pre-clear.post-frame', {
                    allowWhileLoading: true,
                    force: true,
                });
            } else {
                postFrameSettleResult = {
                    rendered: false,
                    reason: MANABI_ENABLE_DID_DISPLAY_POST_FRAME_SETTLE
                        ? 'initial-settle-stable'
                        : 'post-frame-settle-disabled',
                };
            }
            this.#postBookInsetSnapshot('didDisplay.after-post-frame-settle', {
                initialSettleResult,
                postFrameSettleResult,
            });
        } catch (error) {
            postFrameSettleResult = {
                rendered: false,
                reason: 'did-display-error',
                message: error?.message ?? String(error),
            };
            console.error(error);
        }
        let didDisplayVisibleContentState = null;
        let didDisplayNativeLookupTargetCount = null;
        try {
            const doc = this.view?.renderer?.getContents?.()?.[0]?.doc ?? null;
            if (isDocumentLike(doc)) {
                const visibleRange = this.#visibleRangeForDocument(doc);
                let visibleSegmentsResult = this.#visiblePageSegmentResult(
                    doc,
                    visibleRange,
                    'didDisplay.pre-render-ready',
                    {
                        collectionMode: 'initialRenderableProbe',
                        postIfCached: false,
                        includeClientRects: false,
                        postLookupTargets: false,
                        prepareLookupIndex: false,
                        hydrateStatuses: false,
                    }
                );
                didDisplayNativeLookupTargetCount = visibleSegmentsResult?.nativeLookupTargetCount ?? null;
                const visibleContentState = visibleRenderableContentStateForDocument(doc, visibleSegmentsResult);
                didDisplayVisibleContentState = visibleContentState;
                if (
                    globalThis.__manabiInitialRestoreRenderReadyGate?.active === true
                    && visibleContentState.hasRenderableContent === true
                ) {
                    this.#settleInitialDisplayFromVisibleContent('didDisplay.pre-render-ready');
                }
            }
        } catch (error) {
        }
        // Keep the loading cover up through the first paint opportunity after the
        // final paginator settle. Large books can spend another frame (or several
        // blocked frames) applying the column geometry; clearing synchronously here
        // exposes that work as a blank page even though the pre-paint geometry probe
        // already found content.
        if (didDisplayVisibleContentState?.hasRenderableContent === true) {
            const loadingPaintWaitStartedAt = performanceNowMs();
            const markLoadingPaintBoundary = (phase) => {
                const loadingIndicator = document.getElementById('loading-indicator');
                const renderer = this.view?.renderer ?? null;
                manabiTimelineMark('didDisplay.loadingPaintBoundary', {
                    phase,
                    elapsedMs: safeRound(performanceNowMs() - loadingPaintWaitStartedAt, 3),
                    bodyLoading: document.body?.classList?.contains?.('loading') === true,
                    bodyLoadingVisual: document.body?.classList?.contains?.('loading-visual') === true,
                    loadingIndicatorHidden: loadingIndicator?.hasAttribute?.('hidden') ?? null,
                    rendererVisibility: renderer?.style?.visibility || null,
                    rendererDisplay: renderer?.style?.display || null,
                    documentVisibilityState: document.visibilityState ?? null,
                    hasRenderableContent: didDisplayVisibleContentState?.hasRenderableContent === true,
                    visibleSegmentCount: didDisplayVisibleContentState?.visibleSegmentCount ?? null,
                    observedSegmentCount: didDisplayVisibleContentState?.observedSegmentCount ?? null,
                    initialSettleRendered: initialSettleResult?.rendered ?? null,
                    initialSettleReason: initialSettleResult?.reason ?? null,
                    postFrameSettleRendered: postFrameSettleResult?.rendered ?? null,
                    postFrameSettleReason: postFrameSettleResult?.reason ?? null,
                });
            };
            markLoadingPaintBoundary('before-frame-wait');
            await this.#waitForAnimationFrames(1);
            // The final paginator settle has completed and the renderability probe
            // already found visible content. One animation-frame boundary is the
            // first opportunity for that final geometry to paint; a second frame
            // repeats the same full-document layout on large vertical sections.
            markLoadingPaintBoundary('after-frame-1-before-clear');
            this.setLoadingIndicator(false, 'didDisplay');
            markReaderRenderReady('didDisplay.loading-cleared');
            markLoadingPaintBoundary('after-clear');
        }
        this.#postBookInsetSnapshot('didDisplay.loading-cleared', {
            initialSettleResult,
            postFrameSettleResult,
            visibleContentState: didDisplayVisibleContentState,
        });
        try {
            const doc = this.view?.renderer?.getContents?.()?.[0]?.doc ?? null;
            if (isDocumentLike(doc) && !(Number.isFinite(didDisplayNativeLookupTargetCount) && didDisplayNativeLookupTargetCount > 0)) {
                this.#scheduleNativeLookupHitTargetRefreshSettle('didDisplay.render-ready', doc);
            }
        } catch (error) {
            console.error(error);
        }
        if (didDisplayVisibleContentState?.hasRenderableContent === true) {
            globalThis.__manabiPostReaderDocStateEvent?.('didDisplay.loadingCleared');
        }
        if (didDisplayVisibleContentState?.hasRenderableContent === true) {
            this.#resolveInitialDisplaySettled('didDisplay.loading-cleared');
            this.#resolveDisplaySettledWaiters('didDisplay.loading-cleared');
        } else {
            this.#resolveDisplaySettledWaiters('didDisplay.no-visible-text');
        }
        setTimeout(() => {
            this.#postBookInsetSnapshot('didDisplay.loading-cleared.plus-250ms', {
                initialSettleResult,
                postFrameSettleResult,
            });
        }, 250);
        if (didDisplayVisibleContentState?.hasRenderableContent === true) {
            try {
                globalThis.__manabiFinishEPUBLoadWatchdogs?.('didDisplay.loading-cleared');
            } catch (_error) {}
        }
        if (globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay === true) {
            this.navHUD?.setHideNavigationDueToScroll?.(true, 'mark-read.didDisplay.preserve-hidden', {
                stage: 'before-raf',
            });
            globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay = false;
            globalThis.__manabiIgnoreNextIncomingRevealNavigationCount = 0;
        }
        if (this.navHUD?.hideNavigationDueToScroll) {
            this.navHUD.setHideNavigationDueToScroll(true, 'reader.didDisplay.reapply', {
                stage: 'before-raf',
            });
        }
        this.#applyHideNavigationDueToScrollToBookContent(this.navHUD?.hideNavigationDueToScroll === true, 'reader.didDisplay');
        this.#scheduleInitialPaginatorSettle('did-display');
    }
    #onLoad({
        detail: {
            doc
        }
    }) {
        applyStoredChromeInsets('reader.documentLoad');
        applyLayoutSettingsToEbookDocument(doc);
        applyReaderPresentationStateToDocument(doc, globalThis.__manabiReaderPresentationState, 'document-load');
        applyNavigationHiddenStateToEbookDocument(doc, 'document-load');
        const singleMediaInitialLayout = !isCacheWarmerDocument(doc)
            ? classifySingleMediaDocumentForInitialLayout(doc, 'document-load')
            : { applied: false, reason: 'cache-warmer-document' };
        // Foliate fires document load before the paginator has rendered/columnized the
        // content. Running visible-segment sampling here forces layout, finds no
        // candidates, and cannot safely clear loading. The didDisplay path performs
        // the real visible-content pass after render.
        try {
            window.manabiForwardReaderFontToEbookDocuments?.('document-load', doc);
        } catch (error) {
        }
        try {
            window.manabiApplyReaderThemeToEbookDocuments?.('document-load', doc);
        } catch (_error) {}
        try {
            window.manabiApplyReaderFontSizeToEbookDocuments?.('document-load', doc);
        } catch (error) {
        }
        if (!isCacheWarmerDocument(doc)) {
            normalizeManabiSegmentWhitespace(doc);
        }
        if (doc?.fonts?.ready?.then) {
            doc.fonts.ready.then(() => {
                if (!isCacheWarmerDocument(doc) && doc.fonts.status === 'loaded') {
                    this.#invalidateVisiblePageSegmentSnapshot('document.fonts-ready');
                    if (this.hasLoadedLastPosition !== true) {
                        this.#scheduleNativeLookupHitTargetRefreshSettle('document.fonts-ready', doc);
                    }
                }
            }).catch((error) => {
            });
        }
        requestAnimationFrame(() => {
            const sourceHref = doc?.body?.dataset?.mnbSourceHref || null;
            if (!isCacheWarmerDocument(doc)) {
                window.manabi_recordLiveSettledSection?.(sourceHref);
            }
        });
        doc.addEventListener('keydown', this.#handleKeydown.bind(this))
        if (
            doc
            && doc.__manabiMay20BlankTapLoggingInstalled !== true
            && !(MANABI_TEMP_DISABLE_EBOOK_NATIVE_LOOKUP_HIT_TARGETS && isEbookContentDocument(doc))
        ) {
            doc.__manabiMay20BlankTapLoggingInstalled = true;
            let pendingBlankPointerTap = null;
            let lastBlankTouchEnd = null;
            let lastPostedBlankTouchTap = null;
            const touchPointForBlankPointer = event => event.changedTouches?.[0] ?? event.touches?.[0] ?? event;
            const blankPointerPoint = event => {
                const point = touchPointForBlankPointer(event);
                if (!point) return null;
                return {
                    x: point.screenX ?? point.clientX ?? null,
                    y: point.screenY ?? point.clientY ?? null,
                };
            };
            const clearPendingBlankPointerTap = () => {
                pendingBlankPointerTap = null;
            };
            const shouldSuppressSyntheticMouseBlankTap = (event) => {
                const lastTouchTap = lastPostedBlankTouchTap || lastBlankTouchEnd;
                if (event.type !== 'mousedown') {
                    return false;
                }
                if (event.sourceCapabilities?.firesTouchEvents === true) {
                    lastPostedBlankTouchTap = null;
                    lastBlankTouchEnd = null;
                    return true;
                }
                if (!lastTouchTap) {
                    return false;
                }
                lastPostedBlankTouchTap = null;
                lastBlankTouchEnd = null;
                const point = blankPointerPoint(event);
                if (!point || point.x === null || point.y === null) {
                    return true;
                }
                const dx = point.x - lastTouchTap.x;
                const dy = point.y - lastTouchTap.y;
                const shouldSuppress =
                    (dx * dx + dy * dy) <= (manabiSyntheticTouchMouseDistanceThreshold * manabiSyntheticTouchMouseDistanceThreshold);
                return shouldSuppress;
            };
            const blankPointerMovedPastTapThreshold = (event, pending) => {
                const point = touchPointForBlankPointer(event);
                const dx = (point?.screenX ?? point?.clientX ?? pending.startX) - pending.startX;
                const dy = (point?.screenY ?? point?.clientY ?? pending.startY) - pending.startY;
                return (dx * dx + dy * dy) > (manabiBlankNavigationMoveThreshold * manabiBlankNavigationMoveThreshold);
            };
            const closestSegmentForElement = element => {
                if (!element) return null;
                const targetElement = element?.nodeType === 1 ? element : element?.parentElement;
                return targetElement?.closest?.('m-m, .m-m') ?? null;
            };
            const segmentTargetForBlankPointerEvent = (event) => {
                const directSegment = closestSegmentForElement(event.target);
                if (directSegment) return directSegment;
                for (const pathElement of event.composedPath?.() || []) {
                    const pathSegment = closestSegmentForElement(pathElement);
                    if (pathSegment) return pathSegment;
                }
                return null;
            };
            const postContentDocumentBlankPointerTap = (event, source, touchstartAtMs = Date.now()) => {
                const target = event.target;
                const targetElement = target?.nodeType === 1 ? target : target?.parentElement;
                const excludedTarget = targetElement?.closest?.('a, button, input, textarea, select, [role="button"], [contenteditable="true"], m-m, m-s, m-t, .m-m, .m-sentence, ruby, rt');
                const now = Date.now();
                const point = touchPointForBlankPointer(event);
                const segmentTarget = segmentTargetForBlankPointerEvent(event);
                if (segmentTarget) {
                    return;
                }
                if (shouldSuppressSyntheticMouseBlankTap(event)) {
                    return;
                }
                if (excludedTarget) {
                    return;
                }
                const eventKey = [
                    source,
                    event.type,
                    touchstartAtMs,
                    Math.round(point?.screenX ?? point?.clientX ?? -1),
                    Math.round(point?.screenY ?? point?.clientY ?? -1),
                ].join(':');
                if (doc.__manabiLastBlankPointerPostKey !== eventKey) {
                    doc.__manabiLastBlankPointerPostKey = eventKey;
                    const ebookNavigationHidden =
                        globalThis.reader?.navHUD?.hideNavigationDueToScroll === true
                        || doc?.body?.__manabiNavigationHiddenDueToScroll === true
                        || doc?.body?.classList?.contains?.('nav-hidden-due-to-scroll') === true;
                    if (event.type === 'touchend' && point) {
                        const blankX = point.screenX ?? point.clientX ?? null;
                        const blankY = point.screenY ?? point.clientY ?? null;
                        lastPostedBlankTouchTap = blankX !== null && blankY !== null
                            ? { x: blankX, y: blankY }
                            : null;
                        globalThis.__manabiPendingContentDocumentBlankNavigationEcho = lastPostedBlankTouchTap
                            ? { ...lastPostedBlankTouchTap, source, touchstartAtMs }
                            : null;
                    } else {
                        globalThis.__manabiPendingContentDocumentBlankNavigationEcho = null;
                    }
                    window.webkit?.messageHandlers?.touchstartCallbackHandler?.postMessage?.({
                        touchedEntryWithElementId: null,
                        wasAlreadySelected: false,
                        touchstartAtMs,
                        touchstartEventType: event.type,
                        ebookNavigationHidden,
                        source,
                    });
                }
            };
            const handleBlankPointerTouchStart = (event) => {
                const target = event.target;
                const targetElement = target?.nodeType === 1 ? target : target?.parentElement;
                const excludedTarget = targetElement?.closest?.('a, button, input, textarea, select, [role="button"], [contenteditable="true"], m-m, m-s, m-t, .m-m, .m-sentence, ruby, rt');
                const startSegment = segmentTargetForBlankPointerEvent(event);
                if (excludedTarget && !startSegment) {
                    clearPendingBlankPointerTap();
                    return;
                }
                const point = touchPointForBlankPointer(event);
                pendingBlankPointerTap = point
                    ? {
                        startX: point.screenX ?? point.clientX,
                        startY: point.screenY ?? point.clientY,
                        startAtMs: Date.now(),
                    }
                    : null;
            };
            const handleBlankPointerTouchMove = (event) => {
                const pending = pendingBlankPointerTap;
                if (!pending) return;
                if (blankPointerMovedPastTapThreshold(event, pending)) {
                    clearPendingBlankPointerTap();
                }
            };
            const handleBlankPointerTouchEnd = (event) => {
                const pending = pendingBlankPointerTap;
                clearPendingBlankPointerTap();
                if (!pending || event.type === 'touchcancel') {
                    return;
                }
                if (blankPointerMovedPastTapThreshold(event, pending)) {
                    return;
                }
                const point = blankPointerPoint(event);
                const endX = point?.screenX ?? point?.clientX ?? null;
                const endY = point?.screenY ?? point?.clientY ?? null;
                lastBlankTouchEnd = endX !== null && endY !== null
                    ? { x: endX, y: endY }
                    : null;
                postContentDocumentBlankPointerTap(event, 'content-document.blank', pending.startAtMs);
            };
            const handleBlankPointerMouseDown = (event) => {
                postContentDocumentBlankPointerTap(event, 'content-document.blank.mouse');
            };
            doc.addEventListener('touchstart', handleBlankPointerTouchStart, { passive: true, capture: true });
            doc.addEventListener('touchmove', handleBlankPointerTouchMove, { passive: true, capture: true });
            doc.addEventListener('touchend', handleBlankPointerTouchEnd, { passive: true, capture: true });
            doc.addEventListener('touchcancel', handleBlankPointerTouchEnd, { passive: true, capture: true });
            doc.addEventListener('mousedown', handleBlankPointerMouseDown, { passive: true, capture: true });
        }
        installRestorePositionSaveUserInputTracking(doc, 'reader-document');
        window.webkit.messageHandlers.updateCurrentContentPage.postMessage({
            topWindowURL: window.top.location.href,
            currentPageURL: doc.location.href,
        })
        if (MANABI_ENABLE_EBOOK_PAGE_TRACKING_BUTTONS) {
            this.#schedulePageTrackingSync('document-load', doc, 2);
        }
    }

    #resetSideNavChevrons() {
        // Remove visible class & reset opacity immediately
        const leftIcon = document.querySelector('#btn-scroll-left .icon');
        const rightIcon = document.querySelector('#btn-scroll-right .icon');
        [
            { icon: leftIcon, key: 'l' },
            { icon: rightIcon, key: 'r' },
        ].forEach(({ icon, key }) => {
            if (!icon) {
                return;
            }
            this.#resetSideNavChevronAnimation(icon, key);
            icon.classList.remove('chevron-visible');
            icon.classList.remove('chevron-swipe-fade');
            icon.style.opacity = '';
            icon.style.visibility = '';
            this.#chevronOpacityState[key] = 'hidden';
        });
    }

    #postUpdateReadingProgressMessage = debounce(({
        fraction,
        cfi,
        reason,
        currentPageNumber,
        totalPages,
        sectionIndex,
        expectedDocumentURL = null,
        expectedSectionIndex = null,
    }) => {
        let mainDocumentURL = (window.location != window.parent.location) ? document.referrer : document.location.href
        const contents = this.view?.renderer?.getContents?.() || [];
        const content = contents[0] ?? null;
        const doc = content?.doc || content?.document || null;
        const currentDocumentURL = doc?.location?.href ?? null;
        const currentSectionIndex = typeof content?.index === 'number'
            ? content.index
            : (typeof this.view?.renderer?.currentIndex === 'number'
                ? this.view.renderer.currentIndex
                : null);
        const documentMismatch = typeof expectedDocumentURL === 'string'
            && expectedDocumentURL.length > 0
            && currentDocumentURL !== expectedDocumentURL;
        const sectionMismatch = typeof expectedSectionIndex === 'number'
            && typeof currentSectionIndex === 'number'
            && currentSectionIndex !== expectedSectionIndex;
        if (documentMismatch || sectionMismatch) {
            const rendererLoading = this.view?.renderer?.isLoading === true
                || document.body?.classList?.contains?.('loading') === true;
            return;
        }
        const visibleRange = isDocumentLike(doc) ? this.#visibleRangeForDocument(doc) : null;
        const visibleSnapshot = this.visiblePageSegmentSnapshot;
        const visibleSegmentsResult = isDocumentLike(doc)
            && visibleSnapshot
            && visibleSnapshot.generation === this.visiblePageCollectionGeneration
            && visibleSnapshot.doc === doc
            && visibleSnapshot.visibleRange === visibleRange
            ? visibleSnapshot.result
            : null;
        const visibleJapaneseTextState = getVisibleJapaneseTextStateForRenderer(
            this.view?.renderer,
            visibleRange,
            visibleSegmentsResult
        );
        globalThis.__manabiRestoreDebugLog?.('ebook.updateReadingProgress.post', {
            reason,
            fraction: Number.isFinite(fraction) ? safeRound(fraction, 6) : null,
            cfiLength: typeof cfi === 'string' ? cfi.length : 0,
            currentPageNumber,
            totalPages,
            sectionIndex,
            hasVisibleJapaneseText: visibleJapaneseTextState.hasVisibleJapaneseText,
            visibleSegmentCount: visibleJapaneseTextState.visibleSegmentCount,
            observedSegmentCount: visibleJapaneseTextState.observedSegmentCount,
            hasLoadedLastPosition: this.hasLoadedLastPosition === true,
            restoreInProgress: globalThis.__manabiRestoreInProgress === true,
            suppressNextSave: globalThis.__manabiSuppressNextRestoreRelocateSave === true,
            requireUserInputBeforeSave: globalThis.__manabiRequireUserInputBeforePositionSave === true,
            expectedDocumentURL,
            expectedSectionIndex,
            currentDocumentURL,
            currentSectionIndex,
        });
        window.webkit.messageHandlers.updateReadingProgress.postMessage({
            fractionalCompletion: fraction,
            cfi: cfi,
            reason: reason,
            mainDocumentURL: mainDocumentURL,
            currentPageNumber: currentPageNumber,
            totalPages: totalPages,
            sectionIndex: sectionIndex,
            hasVisibleJapaneseText: visibleJapaneseTextState.hasVisibleJapaneseText,
            visibleSegmentCount: visibleJapaneseTextState.visibleSegmentCount,
            observedSegmentCount: visibleJapaneseTextState.observedSegmentCount,
        })
    }, 400)

    async #onRelocate({
        detail
    }) {
        const {
            fraction,
            location,
            tocItem,
            pageItem,
            cfi,
            reason
        } = detail
        const previousVisiblePageSegmentSnapshot = this.visiblePageSegmentSnapshot
            ?? this.lastInvalidatedVisiblePageSegmentSnapshot
            ?? null;
        this.#invalidateVisiblePageSegmentSnapshot('renderer.relocate');
        const isLookupNavigationPageTurn = this.lookupNavigationPageTurnActive === true;
        if (!isLookupNavigationPageTurn) {
            requestLookupCloseForPageMotion('renderer.relocate', {
                reason: reason ?? null,
                fraction: safeRound(fraction),
                currentLocation: location?.current ?? null,
                totalLocation: location?.total ?? null,
            });
        }
        let relocatedVisibleSegmentsResult = null;
        const collectRelocatedVisibleTargets = ({
            collectionMode = null,
            postLookupTargets = true,
            hydrateStatuses = true,
            hydrateSynchronously = null,
            prepareLookupIndex = true,
            includeClientRects = reason !== 'page',
            markerReason = 'visible-targets',
        } = {}) => {
            const isPageRelocate = reason === 'page';
            const pageTurnHydrationOptions = {
                synchronous: hydrateSynchronously === null ? !isPageRelocate : hydrateSynchronously === true,
                adjacentSegmentCount: 0,
                allowPartialTrackedWords: isPageRelocate,
                // The relocated visible page is hydrated in the transition's
                // previous state before commit. Retaining older pages only
                // grows the animated paint set and makes offscreen highlights
                // composite on every later navigation change.
                retainHiddenEbookStatusClasses: false,
            };
            if (isLookupNavigationPageTurn || relocatedVisibleSegmentsResult) {
                if (relocatedVisibleSegmentsResult && hydrateStatuses) {
                    try {
                        const doc = this.view?.renderer?.getContents?.()?.[0]?.doc ?? null;
                        if (isDocumentLike(doc)) {
                            if (postLookupTargets) {
                                const postedTargetCount = this.#postVisiblePageLookupTargets(
                                    doc,
                                    relocatedVisibleSegmentsResult,
                                    `relocate.${markerReason}:${reason ?? 'unknown'}`,
                                    true
                                );
                                if (postedTargetCount !== null) {
                                    relocatedVisibleSegmentsResult.nativeLookupTargetCount = postedTargetCount;
                                }
                            }
                            this.#hydrateVisiblePageTracking(
                                doc,
                                relocatedVisibleSegmentsResult,
                                `relocate.${markerReason}:${reason ?? 'unknown'}`,
                                true,
                                pageTurnHydrationOptions
                            );
                        }
                    } catch (error) {
                        console.error(error);
                    }
                }
                return relocatedVisibleSegmentsResult;
            }
            try {
                const doc = this.view?.renderer?.getContents?.()?.[0]?.doc ?? null;
                if (!isDocumentLike(doc)) {
                    return null;
                }
                const visibleRange = detail?.range?.commonAncestorContainer?.ownerDocument === doc
                    || detail?.range?.startContainer?.ownerDocument === doc
                    || detail?.range?.endContainer?.ownerDocument === doc
                    ? detail.range
                    : visibleRangeForNavigationHUDDocument(this.navHUD, doc);
                const pageTurnDirection = typeof detail?.pageTurnDirection === 'string'
                    ? detail.pageTurnDirection.toLowerCase()
                    : null;
                const sentinelSeedSegmentNodes = reason === 'page'
                    ? pageTurnSentinelSegmentSeedNodes(doc, detail?.visibleSentinelIDs, 8)
                    : null;
                const useOrderedDocumentWindow =
                    reason === 'page'
                    && (!sentinelSeedSegmentNodes || sentinelSeedSegmentNodes.length === 0);
                const seedSegmentNodes = sentinelSeedSegmentNodes?.length > 0 ? sentinelSeedSegmentNodes : null;
                const seedSegmentSource = sentinelSeedSegmentNodes?.length > 0
                    ? `page-turn-sentinel:${detail?.visibleSentinelIDs?.length ?? 0}`
                    : null;
                if (reason === 'page') {
                    manabiTimelineMark('relocate.visible-targets.seedDecision', {
                        reason,
                        pageTurnDirection,
                        visibleRangeSource: detail?.visibleRangeSource ?? null,
                        visibleSentinelIDCount: Array.isArray(detail?.visibleSentinelIDs) ? detail.visibleSentinelIDs.length : 0,
                        sentinelSeedCount: sentinelSeedSegmentNodes?.length ?? 0,
                        selectedSeedCount: seedSegmentNodes?.length ?? 0,
                        selectedSeedSource: seedSegmentSource,
                        useOrderedDocumentWindow,
                        previousSnapshotAvailable: previousVisiblePageSegmentSnapshot?.doc === doc,
                        previousVisibleSegmentCount: previousVisiblePageSegmentSnapshot?.result?.visibleSegments?.length ?? null,
                        previousSource: previousVisiblePageSegmentSnapshot?.result?.segmentCandidateSource ?? null,
                        rangeUsable: visibleRange?.commonAncestorContainer?.ownerDocument === doc
                            || visibleRange?.startContainer?.ownerDocument === doc
                            || visibleRange?.endContainer?.ownerDocument === doc,
                    });
                }
                relocatedVisibleSegmentsResult = this.visiblePageSegmentResult(
                    doc,
                    visibleRange,
                    `relocate.${markerReason}:${reason ?? 'unknown'}`,
                    {
                        collectionMode: collectionMode ?? (
                            reason === 'page' && hydrateStatuses
                                ? 'pageTurnStatusHydration'
                                : (reason === 'page' ? 'pageTurnLookupTargets' : null)
                        ),
                        postIfCached: false,
                        includeClientRects,
                        postLookupTargets,
                        prepareLookupIndex,
                        hydrateStatuses,
                        hydrateStatusesSynchronously: pageTurnHydrationOptions.synchronous,
                        hydrateAdjacentStatusSegmentCount: pageTurnHydrationOptions.adjacentSegmentCount,
                        hydrateAllowPartialTrackedWords: pageTurnHydrationOptions.allowPartialTrackedWords,
                        hydrateRetainHiddenEbookStatusClasses: pageTurnHydrationOptions.retainHiddenEbookStatusClasses,
                        seedSegmentNodes: useOrderedDocumentWindow ? null : seedSegmentNodes,
                        seedSegmentSource: useOrderedDocumentWindow ? null : seedSegmentSource,
                        useOrderedDocumentWindow,
                        includeLookupSurfaceText: reason !== 'page',
                    }
                );
                return relocatedVisibleSegmentsResult;
            } catch (error) {
                console.error(error);
                return null;
            }
        };
        const shouldDeferVisibleTargetCollection =
            !isLookupNavigationPageTurn
            && reason === 'page'
            && document.body?.classList?.contains?.('loading') !== true;
        const relocateVisibleTargetGeneration = this.visiblePageCollectionGeneration;
        let postedPageTurnDisplayReady = false;
        if (!isLookupNavigationPageTurn) {
            const isInitialLoadingRelocate = document.body?.classList?.contains?.('loading') === true;
            if (isInitialLoadingRelocate) {
                // Initial rendering only needs enough identity/geometry to prove that
                // content exists. Lookup-index preparation and tracking-status DOM
                // writes invalidate the just-columnized document and force another
                // full layout before the loading cover can paint. didDisplay schedules
                // that enrichment after the paint boundary.
                collectRelocatedVisibleTargets({
                    collectionMode: 'initialRenderableProbe',
                    postLookupTargets: false,
                    hydrateStatuses: false,
                    prepareLookupIndex: false,
                    includeClientRects: false,
                    markerReason: 'visible-content-initial',
                });
            } else if (shouldDeferVisibleTargetCollection) {
                postNativeLookupPageTurnDisplayReady(`relocate:${reason ?? 'unknown'}`);
                postedPageTurnDisplayReady = true;
                manabiTimelineMark('relocate.visible-targets.immediateLookupOnly', {
                    reason: reason ?? null,
                    generation: relocateVisibleTargetGeneration,
                    pageTurnDirection: detail?.pageTurnDirection ?? null,
                });
                collectRelocatedVisibleTargets({
                    postLookupTargets: true,
                    hydrateStatuses: false,
                    markerReason: 'visible-targets-immediate',
                });
            } else {
                collectRelocatedVisibleTargets();
            }
        }
        await this.navHUD?.handleRelocate(detail);
        if (shouldDeferVisibleTargetCollection) {
            if (!postedPageTurnDisplayReady) {
                postNativeLookupPageTurnDisplayReady(`relocate:${reason ?? 'unknown'}`);
                postedPageTurnDisplayReady = true;
            }
            const scheduleVisibleTargetCollection =
                typeof scheduleAfterNextFrame === 'function'
                    ? scheduleAfterNextFrame
                    : (typeof scheduleNextFrame === 'function'
                        ? scheduleNextFrame
                        : (callback) => callback());
            scheduleVisibleTargetCollection(() => {
                if (relocateVisibleTargetGeneration !== this.visiblePageCollectionGeneration) {
                    return;
                }
                const doc = this.view?.renderer?.getContents?.()?.[0]?.doc ?? null;
                const body = doc?.body ?? null;
                const pendingNavigationTransition = body?.__manabiPendingEbookNavigationTransition ?? null;
                const previousHiddenValue = typeof body?.__manabiPreviousNavigationHiddenDueToScroll === 'boolean'
                    ? body.__manabiPreviousNavigationHiddenDueToScroll
                    : null;
                const nextHiddenValue = typeof body?.__manabiNavigationHiddenDueToScroll === 'boolean'
                    ? body.__manabiNavigationHiddenDueToScroll
                    : null;
                const pendingTransitionMatchesCurrentState =
                    typeof pendingNavigationTransition?.fromHidden === 'boolean'
                    && typeof pendingNavigationTransition?.toHidden === 'boolean'
                    && pendingNavigationTransition.fromHidden !== pendingNavigationTransition.toHidden
                    && nextHiddenValue === pendingNavigationTransition.toHidden;
                const hasExplicitHiddenTransitionState =
                    pendingTransitionMatchesCurrentState
                    || (
                        typeof previousHiddenValue === 'boolean'
                        && typeof nextHiddenValue === 'boolean'
                        && previousHiddenValue !== nextHiddenValue
                    );
                const transitionFromHidden = pendingTransitionMatchesCurrentState
                    ? pendingNavigationTransition.fromHidden
                    : previousHiddenValue === true;
                const transitionToHidden = pendingTransitionMatchesCurrentState
                    ? pendingNavigationTransition.toHidden
                    : nextHiddenValue === true;
                const transitionStage = hasExplicitHiddenTransitionState
                    ? doc?.defaultView?.manabi_prepareEbookTrackingPaintNavigationTransition?.({
                        fromHidden: transitionFromHidden,
                        toHidden: transitionToHidden,
                        reason: `relocate.${reason ?? 'unknown'}`,
                    })
                    : null;
                const needsDeferredLookupTargetPost = relocatedVisibleSegmentsResult === null;
                collectRelocatedVisibleTargets({
                    // Reuse the immediate geometry/identity post when it succeeded. If it could
                    // not collect a document, this deferred pass remains responsible for posting.
                    postLookupTargets: needsDeferredLookupTargetPost,
                    hydrateStatuses: true,
                    hydrateSynchronously: true,
                    markerReason: 'visible-targets',
                });
                if (transitionStage?.staged === true) {
                    doc.defaultView?.manabi_commitEbookTrackingPaintNavigationTransition?.(transitionStage.token);
                }
                if (body?.__manabiPendingEbookNavigationTransition === pendingNavigationTransition) {
                    body.__manabiPendingEbookNavigationTransition = null;
                }
            });
        }
        if (isLookupNavigationPageTurn) {
            this.refreshLookupNavigationVisibleTargetsForRelocate('lookup-navigation.relocate');
            this.resolveDisplaySettledWaiters('relocate.lookup-navigation');
        }
        this.clearLoadingForRelocatedVisibleContent?.(reason ?? 'relocate', relocatedVisibleSegmentsResult);
        const primaryLabelDiagnostics = this.navHUD?.lastPrimaryLabelDiagnostics ?? null;
        const effectiveFractionDiagnostics = getAuthoritativeReaderFractionDiagnostics({
            navHUD: this.navHUD,
            detail,
            fallbackFraction: fraction,
        });
        const effectiveFraction = effectiveFractionDiagnostics.fraction;
        const progressFraction = typeof fraction === 'number' && Number.isFinite(fraction)
            ? Math.max(0, Math.min(1, fraction))
            : effectiveFraction;
        const progressFractionSource = typeof fraction === 'number' && Number.isFinite(fraction)
            ? 'relocate-detail'
            : effectiveFractionDiagnostics.source;
        const currentPercent = typeof primaryLabelDiagnostics?.currentPercent === 'number'
            ? primaryLabelDiagnostics.currentPercent
            : null;
        const sectionIndex =
            typeof detail?.sectionIndex === 'number'
                ? detail.sectionIndex
                : (typeof detail?.index === 'number'
                    ? detail.index
                    : (typeof this.view?.renderer?.currentIndex === 'number'
                        ? this.view.renderer.currentIndex
                        : (typeof getPrimaryRendererContentIndex(this.view?.renderer) === 'number'
                            ? getPrimaryRendererContentIndex(this.view?.renderer)
                        : (typeof this.navHUD?.lastSectionIndexSeen === 'number'
                            ? this.navHUD.lastSectionIndexSeen
                            : null))));
        const sectionBaseCFI = typeof sectionIndex === 'number'
            ? (this.view?.book?.sections?.[sectionIndex]?.cfi ?? null)
            : null;
        const section = typeof sectionIndex === 'number'
            ? (this.view?.book?.sections?.[sectionIndex] ?? null)
            : null;
        let livePageMetrics = null;
        try {
            livePageMetrics = typeof this.view?.renderer?.pageMetrics === 'function'
                ? await this.view.renderer.pageMetrics()
                : null;
        } catch (_error) {
            livePageMetrics = null;
        }
        const liveTextPageTotal = typeof livePageMetrics?.pages === 'number'
            ? Math.max(1, Math.round(livePageMetrics.pages) - 2)
            : null;
        const liveTextPageCurrent = typeof livePageMetrics?.page === 'number' && typeof liveTextPageTotal === 'number'
            ? Math.max(1, Math.min(liveTextPageTotal, Math.round(livePageMetrics.page)))
            : null;
        const snapshotLocalSectionIndex = typeof this.navHUD?.rendererPageSnapshot?.current === 'number'
            ? Math.max(0, this.navHUD.rendererPageSnapshot.current - 1)
            : null;
        const snapshotRendererTotal = typeof this.navHUD?.rendererPageSnapshot?.total === 'number'
            ? this.navHUD.rendererPageSnapshot.total
            : null;
        const localSectionIndex = liveTextPageCurrent != null
            ? liveTextPageCurrent - 1
            : snapshotLocalSectionIndex;
        const rendererTotal = liveTextPageTotal ?? snapshotRendererTotal;
        const cfiLooksSectionBase = typeof cfi === 'string'
            && !!cfi
            && typeof sectionBaseCFI === 'string'
            && cfi === sectionBaseCFI;
        const hasPageScopedObservation = typeof sectionIndex === 'number'
            && typeof localSectionIndex === 'number';
        const priorCFIObservation = this.lastCFIPersistenceObservation;
        let didMarkCFIUnstable = false;
        let cfiIsUnstableAcrossPages = typeof cfi === 'string'
            && !!cfi
            && this.unstableCFIs.has(cfi);
        if (!cfiIsUnstableAcrossPages
            && typeof cfi === 'string'
            && !!cfi
            && hasPageScopedObservation
            && priorCFIObservation?.cfi === cfi
            && (priorCFIObservation.sectionIndex !== sectionIndex
                || priorCFIObservation.localSectionIndex !== localSectionIndex)) {
            this.unstableCFIs.add(cfi);
            cfiIsUnstableAcrossPages = true;
            didMarkCFIUnstable = true;
        }
        this.lastCFIPersistenceObservation = typeof cfi === 'string' && !!cfi && hasPageScopedObservation
            ? {
                cfi,
                sectionIndex,
                localSectionIndex,
                rendererTotal: typeof rendererTotal === 'number' ? rendererTotal : null,
            }
            : null;
        const syntheticRestoreLocator = makeSyntheticRestoreLocator({
            sectionIndex,
            localSectionIndex,
            rendererTotal,
        });
        this.#updateEbookSubscriptionPreviewPageState({
            sectionIndex,
            localSectionIndex,
            rendererTotal,
            reason,
        });
        const shouldPreferSyntheticRestoreLocator = !!syntheticRestoreLocator
            && this.view?.renderer?.localName === 'foliate-paginator'
            && (
                cfiLooksSectionBase
                || cfiIsUnstableAcrossPages
                || typeof cfi !== 'string'
                || cfi.length === 0
            );
        const persistedLocator = shouldPreferSyntheticRestoreLocator
            ? syntheticRestoreLocator
            : cfi;
        const progressBridgePayload = {
            reason: reason ?? null,
            effectiveFraction: Number.isFinite(effectiveFraction) ? safeRound(effectiveFraction, 6) : null,
            effectiveFractionSource: effectiveFractionDiagnostics.source,
            progressFraction: Number.isFinite(progressFraction) ? safeRound(progressFraction, 6) : null,
            progressFractionSource,
            effectivePrimaryLabelFraction: typeof effectiveFractionDiagnostics.primaryLabelFraction === 'number'
                ? safeRound(effectiveFractionDiagnostics.primaryLabelFraction, 6)
                : null,
            effectiveScrubberFraction: typeof effectiveFractionDiagnostics.scrubberFraction === 'number'
                ? safeRound(effectiveFractionDiagnostics.scrubberFraction, 6)
                : null,
            effectiveFallbackFraction: typeof effectiveFractionDiagnostics.fallbackFraction === 'number'
                ? safeRound(effectiveFractionDiagnostics.fallbackFraction, 6)
                : null,
            rawFraction: typeof fraction === 'number' ? safeRound(fraction, 6) : null,
            displayPercent: roundedDisplayPercent(Number.isFinite(effectiveFraction) ? effectiveFraction : fraction),
            currentPercent,
            primaryLabelSource: primaryLabelDiagnostics?.source ?? null,
            primaryLabelText: primaryLabelDiagnostics?.label ?? null,
            primaryLabelFraction: typeof primaryLabelDiagnostics?.fraction === 'number'
                ? safeRound(primaryLabelDiagnostics.fraction, 6)
                : null,
            primaryLabelSectionIndex: typeof primaryLabelDiagnostics?.sectionIndex === 'number'
                ? primaryLabelDiagnostics.sectionIndex
                : null,
            primaryLabelSectionIndexSource: primaryLabelDiagnostics?.sectionIndexSource ?? null,
            primaryLabelResolvedHref: primaryLabelDiagnostics?.resolvedSectionHref ?? null,
            detailLocationCurrent: typeof detail?.location?.current === 'number'
                ? detail.location.current
                : null,
            detailLocationTotal: typeof detail?.location?.total === 'number'
                ? detail.location.total
                : null,
            detailPageNumber: typeof detail?.pageNumber === 'number' ? detail.pageNumber : null,
            detailPageCount: typeof detail?.pageCount === 'number' ? detail.pageCount : null,
            navRendererPageCurrent: typeof this.navHUD?.rendererPageSnapshot?.current === 'number'
                ? this.navHUD.rendererPageSnapshot.current
                : null,
            navRendererPageTotal: typeof this.navHUD?.rendererPageSnapshot?.total === 'number'
                ? this.navHUD.rendererPageSnapshot.total
                : null,
            liveMetricPage: typeof livePageMetrics?.page === 'number' ? livePageMetrics.page : null,
            liveMetricPages: typeof livePageMetrics?.pages === 'number' ? livePageMetrics.pages : null,
            liveMetricSize: typeof livePageMetrics?.size === 'number' ? safeRound(livePageMetrics.size, 2) : null,
            liveMetricViewSize: typeof livePageMetrics?.viewSize === 'number' ? safeRound(livePageMetrics.viewSize, 2) : null,
            liveMetricStart: typeof livePageMetrics?.start === 'number' ? safeRound(livePageMetrics.start, 2) : null,
            liveMetricSource: livePageMetrics?.metricsSource ?? livePageMetrics?.source ?? null,
            sectionIndex,
            sectionHref: typeof section?.id === 'string' ? section.id : null,
            sectionLinear: section?.linear ?? null,
            sectionSize: typeof section?.size === 'number' ? section.size : null,
            localSectionIndex,
            rendererTotal,
            rawCFILength: typeof cfi === 'string' ? cfi.length : 0,
            sectionBaseCFILength: typeof sectionBaseCFI === 'string' ? sectionBaseCFI.length : 0,
            cfiLooksSectionBase,
            cfiIsUnstableAcrossPages,
            syntheticRestoreLocator,
            shouldPreferSyntheticRestoreLocator,
            persistedLocatorKind: shouldPreferSyntheticRestoreLocator
                ? 'synthetic'
                : (typeof cfi === 'string' && cfi ? 'cfi' : 'empty'),
            persistedLocatorLength: typeof persistedLocator === 'string' ? persistedLocator.length : 0,
            hasLoadedLastPosition: this.hasLoadedLastPosition,
            restoreInProgress: globalThis.__manabiRestoreInProgress === true,
            suppressNextRestoreRelocateSave: globalThis.__manabiSuppressNextRestoreRelocateSave === true,
            requiresUserInputBeforePositionSave: globalThis.__manabiRequireUserInputBeforePositionSave === true,
            restoreRequestedFraction: Number.isFinite(globalThis.__manabiRequestedRestoreFraction)
                ? safeRound(globalThis.__manabiRequestedRestoreFraction, 6)
                : null,
            restoreRequestedDisplayPercent: roundedDisplayPercent(globalThis.__manabiRequestedRestoreFraction),
        };
        manabiTimelineMark('viewer.progress.inputs', progressBridgePayload);
        // (removed: setting tocView currentHref here)

        if (this.hasLoadedLastPosition && !globalThis.__manabiRestoreInProgress) {
            if (didMarkCFIUnstable) {
            }
            const normalizedRelocateReason = typeof reason === 'string' ? reason.trim().toLowerCase() : '';
            const shouldSuppressRestoreSettleSave =
                globalThis.__manabiSuppressNextRestoreRelocateSave === true
                && normalizedRelocateReason === 'page';
            if (shouldSuppressRestoreSettleSave) {
                globalThis.__manabiSuppressNextRestoreRelocateSave = false;
            }
            const requiresUserInputBeforePositionSave =
                globalThis.__manabiRequireUserInputBeforePositionSave === true;
            const shouldPersistRelocatePosition =
                normalizedRelocateReason !== 'anchor'
                && !shouldSuppressRestoreSettleSave
                && !requiresUserInputBeforePositionSave;
            if (!shouldPersistRelocatePosition) {
            } else {
                this.#postUpdateReadingProgressMessage({
                    fraction: Number.isFinite(progressFraction) ? progressFraction : fraction,
                    cfi: persistedLocator,
                    reason,
                    currentPageNumber: typeof this.navHUD?.rendererPageSnapshot?.current === 'number'
                        ? this.navHUD.rendererPageSnapshot.current
                        : null,
                    totalPages: typeof rendererTotal === 'number' ? rendererTotal : null,
                    sectionIndex,
                    expectedDocumentURL: (() => {
                        const content = this.view?.renderer?.getContents?.()?.[0] ?? null;
                        return content?.doc?.location?.href ?? content?.document?.location?.href ?? null;
                    })(),
                    expectedSectionIndex: sectionIndex,
                })
            }
        }

        await this.updateNavButtons();

        // Keep percent-jump input in sync with scroll
        const percentInput = document.getElementById('percent-jump-input');
        const percentButton = document.getElementById('percent-jump-button');
        if (percentInput && percentButton) {
            if (Number.isFinite(effectiveFraction)) {
                const pct = Math.round(effectiveFraction * 100);
                percentInput.value = pct;
                this.lastPercentValue = pct;
                percentButton.disabled = true;
            } else {
            }
        }
    }

    async #onNavButtonClick(e) {
        const btn = e.currentTarget;
        const type = btn.dataset.buttonType;
        markRestorePositionSaveUserInput(`nav-button.${type ?? 'unknown'}`);
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
                // Find the last visible .button-label (full or short)
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
        const navSpinnerFallbackTimer = setTimeout(restoreIcon, navSpinnerMaximumMs);
        let nav;
        switch (type) {
                // TODO: Clean up, the scroll cases here won't be reached because of above...
            case 'prev':
                // Go to previous section, then jump to its end
                nav = this.view.renderer.prevSection().then(() => {
                    // TODO: Add this here...
                    //this.view.fraction = 1;
                });
                break;
            case 'next':
                nav = this.view.renderer.nextSection();
                break;
        }
        Promise.resolve(nav).finally(() => {
            clearTimeout(navSpinnerFallbackTimer);
            restoreIcon();
        });
    }
}

//const open = async (file) => {
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


window.setEbookViewerLayout = (layoutMode) => {
    const normalizedLayoutMode = typeof layoutMode === 'string' && layoutMode.length > 0 ? layoutMode : 'paginated';
    if (globalThis.__manabiEbookViewerLayoutMode === normalizedLayoutMode) {
        applyStoredChromeInsets('setEbookViewerLayout.same');
        return;
    }
    globalThis.__manabiEbookViewerLayoutMode = normalizedLayoutMode;
    // TODO: Add scrolled mode back...
//    globalThis.reader.view.renderer.setAttribute('flow', layoutMode)
    applyStoredChromeInsets('setEbookViewerLayout');
    globalThis.manabiInvalidateVisiblePageSegmentSnapshot?.('layout-change');
}

window.setEbookViewerWritingDirection = (writingDirection) => {
    const normalizedWritingDirection = 'original';
    if (globalThis.__manabiEbookViewerWritingDirection === normalizedWritingDirection) {
        return;
    }
    globalThis.__manabiEbookViewerWritingDirection = normalizedWritingDirection;
    const renderer = globalThis.reader?.view?.renderer ?? null;
    const contents = renderer?.getContents?.() || [];
    const clearForcedWritingDirection = (doc) => {
        const body = doc?.body;
        if (!body) return false;
        if (body.dataset.mnbForcedWritingDirection) {
            body.classList?.remove?.('reader-vertical-writing');
            doc.documentElement?.classList?.remove?.('vrtl');
            body.removeAttribute('data-mnb-writing-direction');
            body.removeAttribute('data-mnb-foliate-writing-direction');
            body.removeAttribute('data-mnb-foliate-writing-mode');
        }
        body.removeAttribute('data-mnb-forced-writing-direction');
        try {
            doc.defaultView?.manabiApplyVerticalWritingCheck?.();
        } catch (_error) {}
        return true;
    };
    for (const content of contents) {
        clearForcedWritingDirection(content?.doc ?? content?.document ?? null);
    }
    globalThis.manabiInvalidateVisiblePageSegmentSnapshot?.('writing-direction-change');
}

window.loadEBook = ({
    url,
    layoutMode,
    initialRestore,
    readerPresentationState,
}) => {
    const normalizedReaderPresentationState = installReaderPresentationState(readerPresentationState, 'loadEBook');
    const requestedURL = typeof url === 'string' ? url : '';
    globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.incoming', {
        hasInitialRestore: !!initialRestore,
        requestID: typeof initialRestore?.requestID === 'string' ? initialRestore.requestID : null,
        requestedLocator: typeof initialRestore?.requestedLocator === 'string' ? initialRestore.requestedLocator : null,
        incomingFractionType: typeof initialRestore?.fractionalCompletion,
        incomingFractionValue: initialRestore?.fractionalCompletion ?? null,
        incomingCFILength: typeof initialRestore?.cfi === 'string' ? initialRestore.cfi.length : 0,
    });
    const requestedRestoreFraction = coerceRestoreFraction(initialRestore?.fractionalCompletion);
    const effectiveInitialRestore = initialRestore
        ? {
            ...initialRestore,
            ...(requestedRestoreFraction != null ? { fractionalCompletion: requestedRestoreFraction } : {}),
        }
        : null;
    const requestedSyntheticRestore = parseSyntheticRestoreLocator(effectiveInitialRestore?.cfi);
    const requestedSpineOnlySectionIndex = !requestedSyntheticRestore
        ? parseSpineOnlyEpubCFI(effectiveInitialRestore?.cfi)
        : null;
    const hasRequestedSpineOnlyRestore = Number.isInteger(requestedSpineOnlySectionIndex);
    const requestedRestoreCFI = !requestedSyntheticRestore
        && !hasRequestedSpineOnlyRestore
        && typeof effectiveInitialRestore?.cfi === 'string'
        ? effectiveInitialRestore.cfi
        : '';
    const requestedRestoreKind = requestedSyntheticRestore
        ? 'synthetic'
        : (hasRequestedSpineOnlyRestore ? 'spine-cfi' : (requestedRestoreCFI.length > 0 ? 'cfi' : (requestedRestoreFraction != null && requestedRestoreFraction > 0 ? 'fraction' : 'none')));
    const hasExplicitInitialRestoreTarget = !!effectiveInitialRestore && requestedRestoreKind !== 'none';
    globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.normalizedRestore', {
        hasInitialRestore: !!effectiveInitialRestore,
        requestID: typeof effectiveInitialRestore?.requestID === 'string' ? effectiveInitialRestore.requestID : null,
        requestedLocator: typeof effectiveInitialRestore?.requestedLocator === 'string' ? effectiveInitialRestore.requestedLocator : null,
        restoreKind: requestedRestoreKind,
        requestedFraction: requestedRestoreFraction != null ? safeRound(requestedRestoreFraction, 6) : null,
        effectiveFractionType: typeof effectiveInitialRestore?.fractionalCompletion,
        effectiveFractionValue: effectiveInitialRestore?.fractionalCompletion ?? null,
        syntheticSectionIndex: requestedSyntheticRestore?.sectionIndex ?? null,
        spineSectionIndex: requestedSpineOnlySectionIndex ?? null,
        hasSpineOnlyRestore: hasRequestedSpineOnlyRestore,
        hasPreciseCFI: requestedRestoreCFI.length > 0,
    });
    globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.call', {
        hasURL: requestedURL.length > 0,
        layoutMode: layoutMode || null,
        hasInitialRestore: !!effectiveInitialRestore,
        initialCFILength: typeof effectiveInitialRestore?.cfi === 'string' ? effectiveInitialRestore.cfi.length : 0,
        restoreKind: requestedRestoreKind,
        syntheticSectionIndex: requestedSyntheticRestore?.sectionIndex ?? null,
        syntheticLocalPage: requestedSyntheticRestore?.localSectionIndex ?? null,
        syntheticRendererTotal: requestedSyntheticRestore?.rendererTotal ?? null,
        spineSectionIndex: requestedSpineOnlySectionIndex ?? null,
        requestedFraction: requestedRestoreFraction != null ? safeRound(requestedRestoreFraction, 6) : null,
        rawFractionType: typeof initialRestore?.fractionalCompletion,
        rawFractionValue: initialRestore?.fractionalCompletion ?? null,
        existingURLMatches: requestedURL.length > 0 && globalThis.manabiLoadEBookURL === requestedURL,
        existingInFlight: globalThis.manabiLoadEBookInFlight === true,
        existingReady: globalThis.manabiLoadEBookReady === true,
        hasRenderer: !!globalThis.reader?.view?.renderer,
        previousState: globalThis.manabiLoadEBookLastState || null,
    });
    if (
        requestedURL.length > 0
        && globalThis.manabiLoadEBookURL === requestedURL
        && globalThis.manabiLoadEBookInFlight === true
    ) {
        const existingStartedAt = Number(globalThis.manabiLoadEBookStartedAt || 0);
        const existingStartedAgeMs = existingStartedAt > 0 ? Date.now() - existingStartedAt : 0;
        if (globalThis.reader?.view?.renderer || existingStartedAgeMs < 2500) {
            const willQueueInitialRestore = !!effectiveInitialRestore;
            if (willQueueInitialRestore) {
                globalThis.__manabiPendingInitialRestore = effectiveInitialRestore;
            }
            globalThis.manabiLoadEBookLastState = willQueueInitialRestore
                ? 'duplicate-inflight-pending-restore'
                : 'duplicate-inflight';
            globalThis.manabiPendingLoadEBookArgs = null;
            globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.return', {
                path: globalThis.manabiLoadEBookLastState,
                existingStartedAgeMs,
                hasInitialRestore: !!effectiveInitialRestore,
                queuedInitialRestore: willQueueInitialRestore,
                restoreKind: requestedRestoreKind,
                requestedFraction: requestedRestoreFraction != null ? safeRound(requestedRestoreFraction, 6) : null,
                hasRenderer: !!globalThis.reader?.view?.renderer,
            });
            return globalThis.manabiLoadEBookPromise;
        }
        globalThis.manabiLoadEBookLastState = 'duplicate-inflight-stale-restart';
    }
    if (
        requestedURL.length > 0
        && globalThis.manabiLoadEBookURL === requestedURL
        && globalThis.manabiLoadEBookReady === true
        && globalThis.reader?.view?.renderer
    ) {
        globalThis.manabiLoadEBookLastState = 'duplicate-ready';
        globalThis.manabiPendingLoadEBookArgs = null;
        globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.return', {
            path: 'duplicate-ready',
            hasInitialRestore: !!effectiveInitialRestore,
            initialRestoreHandled: !!globalThis.__manabiInitialRestoreHandled,
            hasRenderer: !!globalThis.reader?.view?.renderer,
            hasLoadedLastPosition: globalThis.reader?.hasLoadedLastPosition === true,
        });
        return;
    }
    const loadToken = (globalThis.manabiLoadEBookToken ?? 0) + 1;
    globalThis.manabiLoadEBookToken = loadToken;
    globalThis.manabiLoadEBookURL = requestedURL;
    globalThis.manabiLoadEBookInFlight = true;
    globalThis.manabiLoadEBookStarted = true;
    globalThis.manabiLoadEBookStartedAt = Date.now();
    globalThis.manabiLoadEBookReady = false;
    globalThis.manabiLoadEBookLastState = 'start';
    globalThis.__manabiInitialRestoreResult = null;
    clearInitialRestoreRenderReadyGate('loadEBook.newLoad');
    if (hasExplicitInitialRestoreTarget) {
        enableInitialRestoreRenderReadyGate('loadEBook.initialRestore', {
            restoreKind: requestedRestoreKind,
            requestedFraction: requestedRestoreFraction != null ? safeRound(requestedRestoreFraction, 6) : null,
            cfiLength: typeof effectiveInitialRestore?.cfi === 'string' ? effectiveInitialRestore.cfi.length : null,
        });
    }
    globalThis.manabiPendingLoadEBookArgs = {
        hasURL: typeof url === 'string' && url.length > 0,
        layoutMode: layoutMode || null,
        hasInitialRestore: !!effectiveInitialRestore,
        hasReaderPresentationState: !!normalizedReaderPresentationState,
    };
    if (globalThis.__manabiInitialForegroundCriticalSectionToken) {
        finishForegroundCriticalSection(globalThis.__manabiInitialForegroundCriticalSectionToken, 'loadEBook.replace');
        globalThis.__manabiInitialForegroundCriticalSectionToken = null;
    }
    globalThis.__manabiInitialForegroundCriticalSectionToken = beginForegroundCriticalSection(`loadEBook:${loadToken}`);
    const finishInitialForegroundCriticalSection = (reason) => {
        if (globalThis.manabiLoadEBookToken !== loadToken) {
            return;
        }
        const token = globalThis.__manabiInitialForegroundCriticalSectionToken;
        if (!token) {
            return;
        }
        finishForegroundCriticalSection(token, reason);
        if (globalThis.__manabiInitialForegroundCriticalSectionToken === token) {
            globalThis.__manabiInitialForegroundCriticalSectionToken = null;
        }
        if (globalThis.__manabiFinishInitialForegroundCriticalSection === finishInitialForegroundCriticalSection) {
            globalThis.__manabiFinishInitialForegroundCriticalSection = null;
        }
    };
    globalThis.__manabiFinishInitialForegroundCriticalSection = finishInitialForegroundCriticalSection;
    try {
        globalThis.__manabiFinishEPUBLoadWatchdogs?.('new-load');
    } catch (_error) {}
    globalThis.__manabiLiveProcessedSectionHrefs = new Set();
    globalThis.__manabiLiveSettledSectionHrefs = new Set();
    globalThis.__manabiFirstLiveSectionHref = null;
    const finishLoadWatchdogs = () => {
    };
    globalThis.__manabiFinishEPUBLoadWatchdogs = finishLoadWatchdogs;
    const previousReader = globalThis.reader?.view?.renderer ? globalThis.reader : null;
    try {
        globalThis.reader?.view?.close?.()
    } catch (_error) {}
    try {
        globalThis.reader?.view?.remove?.()
    } catch (_error) {}
    let reader = new Reader()
    globalThis.reader = reader
    reader.setLoadingIndicator(true, 'loadEBook.start');

    window.ebookSource = typeof url === 'string' && url.length > 0 && url.startsWith('ebook://')
        ? makeNativeSource(url)
        : null

    if (url) {
        globalThis.manabiLoadEBookLastState = 'source-start';
        const sourcePromise = window.ebookSource
            ? Promise.resolve(window.ebookSource).then((source) => {
                return source;
            })
            : fetch(url, {
                headers: {
                    "IS-SWIFTUIWEBVIEW-VIEWER-FILE-REQUEST": "true",
                },
            })
                .then(res => {
                    return res.blob();
                })
                .then((blob) => {
                    window.blob = blob
                    return makeFileSource(new File([blob], new URL(url).pathname))
                })

        const openPromise = sourcePromise
        .then(async (source) => {
            if (globalThis.manabiLoadEBookToken !== loadToken) return;
            globalThis.manabiLoadEBookLastState = 'source-ready';
            globalThis.manabiPendingLoadEBookArgs = null;
            if (source?.kind === 'native') {
            }
            if (layoutMode) {
                window.initialLayoutMode = layoutMode
                globalThis.__manabiEbookViewerLayoutMode = layoutMode
            }
            const pendingInitialRestoreAtOpen = globalThis.__manabiPendingInitialRestore ?? null;
            const initialRestoreForOpen = effectiveInitialRestore;
            globalThis.manabiLoadEBookLastState = 'reader-open-dispatch';
            globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.readerOpen.dispatch', {
                loadToken,
                hasInitialRestore: !!initialRestoreForOpen,
                hasPendingInitialRestore: !!pendingInitialRestoreAtOpen,
                requestID: typeof initialRestoreForOpen?.requestID === 'string' ? initialRestoreForOpen.requestID : null,
                requestedLocator: typeof initialRestoreForOpen?.requestedLocator === 'string' ? initialRestoreForOpen.requestedLocator : null,
                initialCFILength: typeof initialRestoreForOpen?.cfi === 'string' ? initialRestoreForOpen.cfi.length : 0,
                restoreKind: requestedRestoreKind,
                syntheticSectionIndex: requestedSyntheticRestore?.sectionIndex ?? null,
                spineSectionIndex: requestedSpineOnlySectionIndex ?? null,
                requestedFraction: coerceRestoreFraction(initialRestoreForOpen?.fractionalCompletion) != null
                    ? safeRound(coerceRestoreFraction(initialRestoreForOpen?.fractionalCompletion), 6)
                    : null,
            });
            await reader.open(source, {
                initialRestore: initialRestoreForOpen,
                readerPresentationState: normalizedReaderPresentationState,
            })
            if (!reader?.view?.renderer) {
                throw new Error('reader-open-missing-renderer');
            }
            const postOpenLocation = reader?.view?.lastLocation ?? null;
            globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.readerOpen.finish', {
                loadToken,
                hasInitialRestore: !!effectiveInitialRestore,
                initialRestoreHandled: !!globalThis.__manabiInitialRestoreHandled,
                lastLocationFraction: typeof postOpenLocation?.fraction === 'number' ? safeRound(postOpenLocation.fraction, 6) : null,
                lastLocationCurrent: postOpenLocation?.location?.current ?? null,
                lastLocationTotal: postOpenLocation?.location?.total ?? null,
                sectionIndex: typeof postOpenLocation?.section?.current === 'number'
                    ? postOpenLocation.section.current
                    : (typeof postOpenLocation?.sectionIndex === 'number' ? postOpenLocation.sectionIndex : null),
                hasLoadedLastPosition: reader?.hasLoadedLastPosition === true,
            });
            if (globalThis.__manabiInitialRestoreHandled) {
                finalizeInitialRestoreHandledWithoutNativeRestore('loadEBook.initialRestoreHandled');
            }
            const pendingInitialRestoreAfterOpen = globalThis.__manabiPendingInitialRestore ?? null;
            const shouldDeferReaderOpenLoadingClear =
                globalThis.__manabiInitialRestoreRenderReadyGate?.active === true
                && !globalThis.__manabiInitialRestoreHandled
                && (!!initialRestoreForOpen || !!pendingInitialRestoreAfterOpen);
            if (shouldDeferReaderOpenLoadingClear) {
            } else {
                const settled = reader.settleInitialDisplayFromVisibleContent?.('readerOpenResolved');
                if (settled?.settled !== true) {
                    globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.readerOpen.loadingRetained', {
                        loadToken,
                        reason: settled?.reason ?? 'not-settled',
                        visibleSegmentCount: settled?.visibleSegmentCount ?? null,
                        observedSegmentCount: settled?.observedSegmentCount ?? null,
                    });
                }
            }
            if (pendingInitialRestoreAfterOpen) {
                globalThis.__manabiPendingInitialRestore = null;
                const pendingFraction = coerceRestoreFraction(pendingInitialRestoreAfterOpen?.fractionalCompletion);
                globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.pendingRestore.apply', {
                    loadToken,
                    cfiLength: typeof pendingInitialRestoreAfterOpen?.cfi === 'string' ? pendingInitialRestoreAfterOpen.cfi.length : 0,
                    requestedFraction: pendingFraction != null ? safeRound(pendingFraction, 6) : null,
                    initialRestoreHandledBeforeApply: !!globalThis.__manabiInitialRestoreHandled,
                    hasLoadedLastPositionBeforeApply: reader?.hasLoadedLastPosition === true,
                });
                let pendingRestoreSucceeded = false;
                try {
                    await window.loadLastPosition?.({
                        cfi: typeof pendingInitialRestoreAfterOpen?.cfi === 'string' ? pendingInitialRestoreAfterOpen.cfi : '',
                        fractionalCompletion: pendingInitialRestoreAfterOpen?.fractionalCompletion,
                    });
                    pendingRestoreSucceeded = globalThis.reader?.hasLoadedLastPosition === true
                        && !!globalThis.__manabiInitialRestoreHandled;
                } catch (error) {
                }
                if (shouldDeferReaderOpenLoadingClear) {
                    const settled = reader.settleInitialDisplayFromVisibleContent?.('loadEBook.pendingRestoreAfterApply');
                    finishInitialRestoreRenderReadyGateWithTerminalResult('loadEBook.pendingRestoreAfterApply');
                    reader.setLoadingIndicator(false, settled?.settled === true
                        ? 'loadEBook.pendingRestoreAfterApply.visibleContent'
                        : 'loadEBook.pendingRestoreAfterApply.terminal');
                }
                globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.pendingRestore.finish', {
                    loadToken,
                    restored: pendingRestoreSucceeded,
                    initialRestoreHandledAfterApply: !!globalThis.__manabiInitialRestoreHandled,
                    hasLoadedLastPositionAfterApply: globalThis.reader?.hasLoadedLastPosition === true,
                    currentFraction: typeof globalThis.reader?.view?.lastLocation?.fraction === 'number'
                        ? safeRound(globalThis.reader.view.lastLocation.fraction, 6)
                        : null,
                });
            }
            if (initialRestoreForOpen && !globalThis.__manabiInitialRestoreHandled) {
                const postOpenLocation = reader?.view?.lastLocation ?? null;
                globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.initialRestore.notHandledAfterOpen', {
                    loadToken,
                    restoreKind: requestedRestoreKind,
                    requestedFraction: requestedRestoreFraction != null ? safeRound(requestedRestoreFraction, 6) : null,
                    currentFraction: typeof postOpenLocation?.fraction === 'number' ? safeRound(postOpenLocation.fraction, 6) : null,
                    currentSectionIndex: typeof postOpenLocation?.section?.current === 'number'
                        ? postOpenLocation.section.current
                        : (typeof postOpenLocation?.sectionIndex === 'number' ? postOpenLocation.sectionIndex : null),
                    hasLoadedLastPosition: reader?.hasLoadedLastPosition === true,
                    action: 'finishTerminalRestoreGate',
                });
                const settled = reader.settleInitialDisplayFromVisibleContent?.('loadEBook.initialRestoreNotHandledAfterOpen');
                finishInitialRestoreRenderReadyGateWithTerminalResult('loadEBook.initialRestoreNotHandledAfterOpen');
                // The visible fallback remains interactive, but it is not a
                // successful restore and must not overwrite the saved locator.
                reader.hasLoadedLastPosition = false;
                reader.setLoadingIndicator(false, settled?.settled === true
                    ? 'loadEBook.initialRestoreNotHandledAfterOpen.visibleContent'
                    : 'loadEBook.initialRestoreNotHandledAfterOpen.terminal');
            } else if (
                shouldDeferReaderOpenLoadingClear
                && !globalThis.__manabiInitialRestoreHandled
                && globalThis.__manabiInitialRestoreRenderReadyGate?.active === true
            ) {
                const settled = reader.settleInitialDisplayFromVisibleContent?.('loadEBook.initialRestoreDeferredTerminal');
                finishInitialRestoreRenderReadyGateWithTerminalResult('loadEBook.initialRestoreDeferredTerminal');
                reader.hasLoadedLastPosition = false;
                reader.setLoadingIndicator(false, settled?.settled === true
                    ? 'loadEBook.initialRestoreDeferredTerminal.visibleContent'
                    : 'loadEBook.initialRestoreDeferredTerminal.terminal');
            }
        })
        .then(async () => {
            if (globalThis.manabiLoadEBookToken !== loadToken) return;
            globalThis.reader = reader;
            finishLoadWatchdogs();
            globalThis.manabiLoadEBookReady = true;
            globalThis.manabiLoadEBookLastState = 'reader-open-resolved';
            const initialRestoreResult = globalThis.__manabiInitialRestoreResult ?? null;
            const liveLoadedFraction = manabiFractionFromLocation(globalThis.reader?.view?.lastLocation ?? null);
            const initialRestoreCurrentFraction = initialRestoreResult?.currentFraction ?? liveLoadedFraction;
            const initialRestoreHandledFraction = initialRestoreResult?.handledFractionalCompletion
                ?? (initialRestoreResult?.restoreSatisfied === true ? initialRestoreCurrentFraction : null);
            const probe = globalThis.reader?.collectLayoutGapProbe?.('ebookViewerLoaded', {
                bookDir: globalThis.reader?.bookDir || null,
                isRTL: !!globalThis.reader?.isRTL,
            }) ?? null;
            window.webkit.messageHandlers.ebookViewerLoaded.postMessage({
                probe,
                initialRestoreResult,
                initialRestoreHandled: initialRestoreResult?.restoreSatisfied ?? false,
                initialRestoreCurrentFractionalCompletion: initialRestoreCurrentFraction,
                initialRestoreFractionalCompletion: initialRestoreHandledFraction,
            })
        })
        .catch((error) => {
            if (globalThis.manabiLoadEBookToken !== loadToken) {
                return;
            }
            finishInitialForegroundCriticalSection('loadEBook.error');
            finishLoadWatchdogs();
            globalThis.manabiLoadEBookReady = false;
            globalThis.manabiLoadEBookLastState = `open-error:${error?.message || String(error)}`;
            if (globalThis.reader === reader || !globalThis.reader?.view?.renderer) {
                globalThis.reader = previousReader ?? null;
            }
            for (const candidateReader of new Set([reader, previousReader, globalThis.reader].filter(Boolean))) {
                try {
                    candidateReader?.setLoadingIndicator?.(false, 'loadEBook.error');
                } catch (_error) {}
            }
            throw error;
        })
        .finally(() => {
            if (globalThis.manabiLoadEBookToken !== loadToken) return;
            globalThis.manabiLoadEBookInFlight = false;
            globalThis.manabiLoadEBookPromise = null;
        })
        globalThis.manabiLoadEBookPromise = openPromise;
        return openPromise;
    } else {
        finishInitialForegroundCriticalSection('loadEBook.no-url');
        finishLoadWatchdogs();
        globalThis.manabiLoadEBookReady = false;
        globalThis.manabiLoadEBookLastState = 'no-url';
        globalThis.manabiPendingLoadEBookArgs = null;
        globalThis.manabiLoadEBookInFlight = false;
        globalThis.manabiLoadEBookPromise = null;
    }
    //.catch(e => console.error(e))
}

const markRestorePositionSaveUserInput = (source = 'unknown') => {
    if (globalThis.__manabiRequireUserInputBeforePositionSave !== true) {
        return;
    }
    globalThis.__manabiRequireUserInputBeforePositionSave = false;
    globalThis.__manabiSuppressNextRestoreRelocateSave = false;
};

const markRestorePositionSavePageTurnInput = (source = 'page-turn') => {
    markRestorePositionSaveUserInput(source);
};

const ensureRestorePositionSaveUserInputTracking = () => {
    if (globalThis.__manabiRestoreUserInputTrackingInstalled === true) {
        return;
    }
    globalThis.__manabiRestoreUserInputTrackingInstalled = true;
    for (const eventName of ['pointerdown', 'touchstart', 'wheel', 'keydown', 'click']) {
        window.addEventListener(eventName, (event) => {
            markRestorePositionSaveUserInput(`window.${event?.type ?? eventName}`);
        }, {
            capture: true,
            passive: true,
        });
    }
};

const installRestorePositionSaveUserInputTracking = (target, source) => {
    if (!target?.addEventListener) {
        return;
    }
    for (const eventName of ['pointerdown', 'touchstart', 'wheel', 'keydown', 'click']) {
        target.addEventListener(eventName, (event) => {
            markRestorePositionSaveUserInput(`${source}.${event?.type ?? eventName}`);
        }, {
            capture: true,
            passive: true,
        });
    }
};

const finalizeInitialRestoreHandledWithoutNativeRestore = (reason = 'loadEBook.initialRestoreHandled') => {
    const handled = globalThis.__manabiInitialRestoreHandled ?? null;
    if (!handled || !globalThis.reader?.view?.renderer) {
        return false;
    }
    ensureRestorePositionSaveUserInputTracking();
    globalThis.__manabiSuppressNextRestoreRelocateSave = true;
    globalThis.__manabiRequireUserInputBeforePositionSave = true;
    globalThis.__manabiRestoreInProgress = false;
    globalThis.reader.completeLastPositionLoad(reason);
    const visibleSettleResult = globalThis.reader.settleInitialDisplayFromVisibleContent?.(`${reason}.visibleContent`);
    if (visibleSettleResult?.settled === true) {
        clearInitialRestoreRenderReadyGate(reason);
        markReaderRenderReady(reason);
    }
    globalThis.reader.refreshNativeMarkReadState?.(`${reason}.markRead`);
    globalThis.__manabiRestoreDebugLog?.('ebook.initialRestore.finalized', {
        reason,
        sectionIndex: handled.sectionIndex ?? null,
        localSectionIndex: handled.localSectionIndex ?? null,
        rendererTotal: handled.rendererTotal ?? null,
        fractionalCompletion: Number.isFinite(handled.fractionalCompletion) ? safeRound(handled.fractionalCompletion, 6) : null,
        cfiLength: typeof handled.cfi === 'string' ? handled.cfi.length : 0,
        hasLoadedLastPosition: globalThis.reader?.hasLoadedLastPosition === true,
        suppressNextSave: globalThis.__manabiSuppressNextRestoreRelocateSave === true,
        requireUserInputBeforeSave: globalThis.__manabiRequireUserInputBeforePositionSave === true,
    });
    return true;
};

window.loadLastPosition = async ({
    cfi,
    fractionalCompletion,
    navigationTimeoutMs = 45000,
    stateSettleTimeoutMs = 45000,
}) => {
    const previouslyHandledInitialRestore = globalThis.__manabiInitialRestoreHandled ?? null;
    ensureRestorePositionSaveUserInputTracking();
    globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.incoming', {
        incomingFractionType: typeof fractionalCompletion,
        incomingFractionValue: fractionalCompletion ?? null,
        incomingCFILength: typeof cfi === 'string' ? cfi.length : 0,
    });
    fractionalCompletion = coerceRestoreFraction(fractionalCompletion);
    globalThis.__manabiRequestedRestoreFraction = Number.isFinite(fractionalCompletion)
        ? Math.max(0, Math.min(1, fractionalCompletion))
        : null;
    globalThis.__manabiRestoreInProgress = true;
    const restoreNavigationTimeoutMs = Number.isFinite(navigationTimeoutMs) && navigationTimeoutMs > 0
        ? navigationTimeoutMs
        : 45000;
    const restoreStateSettleTimeoutMs = Number.isFinite(stateSettleTimeoutMs) && stateSettleTimeoutMs > 0
        ? stateSettleTimeoutMs
        : 45000;
    const runRestoreNavigation = async (
        intent,
        operation,
        {
            timeoutMs = restoreNavigationTimeoutMs,
            throwOnError = true,
        } = {},
    ) => {
        try {
            const result = await runWithNavigationIntent(intent, operation, { timeoutMs });
            return {
                ok: true,
                result,
            };
        } catch (error) {
            if (throwOnError) {
                throw error;
            }
            return {
                ok: false,
                error,
            };
        }
    };
    const waitForFrames = async (count = 2) => {
        for (let index = 0; index < count; index += 1) {
            await new Promise((resolve) => requestAnimationFrame(() => resolve()));
        }
    };
    const waitForPaintAfterNavigation = async () => {
        await waitForFrames(2);
    };
    const captureRestoreState = (stage, extra = {}) => {
        const detail = globalThis.reader?.view?.lastLocation ?? null;
        const currentFraction = typeof detail?.fraction === 'number' ? detail.fraction : null;
        const locationCurrent = typeof detail?.location?.current === 'number' ? detail.location.current : null;
        const locationTotal = typeof detail?.location?.total === 'number' ? detail.location.total : null;
        const sectionIndex = typeof detail?.section?.current === 'number'
            ? detail.section.current
            : (typeof detail?.sectionIndex === 'number' ? detail.sectionIndex : null);
        return {
            detail,
            currentFraction,
            locationCurrent,
            locationTotal,
            sectionIndex,
        };
    };
    const hasFractionalCompletion = Number.isFinite(fractionalCompletion) && fractionalCompletion > 0;
    const restoreStateHasUsableLocation = (state) => {
        if (!state) return false;
        if (hasFractionalCompletion) {
            return typeof state.currentFraction === 'number';
        }
        return typeof state.currentFraction === 'number'
            || typeof state.sectionIndex === 'number'
            || typeof state.locationCurrent === 'number';
    };
    const restoreStateFractionSatisfied = (state) => !hasFractionalCompletion
        || (
            typeof state?.currentFraction === 'number'
            && Math.abs(state.currentFraction - fractionalCompletion) <= 0.003
        );
    const waitForRestoreStateIfNeeded = async (
        state,
        reason,
        stage,
        {
            requireFractionSatisfied = false,
            timeoutMs = restoreStateSettleTimeoutMs,
        } = {},
    ) => {
        if (
            restoreStateHasUsableLocation(state)
            && (!requireFractionSatisfied || restoreStateFractionSatisfied(state))
        ) {
            return state;
        }
        globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.restoreState.wait.start', {
            reason,
            stage,
            timeoutMs,
            requireFractionSatisfied,
            requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
            currentFraction: typeof state?.currentFraction === 'number' ? safeRound(state.currentFraction, 6) : null,
            currentSectionIndex: state?.sectionIndex ?? null,
            locationCurrent: state?.locationCurrent ?? null,
            locationTotal: state?.locationTotal ?? null,
            renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
        });
        await waitForPaintAfterNavigation();
        const visibleSettleResult = typeof globalThis.reader?.settleInitialDisplayFromVisibleContent === 'function'
            ? globalThis.reader.settleInitialDisplayFromVisibleContent(`loadLastPosition.${reason}`)
            : null;
        let waitedState = captureRestoreState(stage, {
            waitedForDisplay: false,
            visibleContentSettled: visibleSettleResult?.settled === true,
        });
        let displaySettledResult = null;
        if (
            (!restoreStateHasUsableLocation(waitedState)
                || (requireFractionSatisfied && !restoreStateFractionSatisfied(waitedState)))
            && typeof globalThis.reader?.waitForNextDisplaySettled === 'function'
        ) {
            displaySettledResult = await globalThis.reader.waitForNextDisplaySettled(
                `loadLastPosition.${reason}`,
                { timeoutMs }
            );
            waitedState = captureRestoreState(stage, {
                waitedForDisplay: true,
                visibleContentSettled: visibleSettleResult?.settled === true,
                displaySettledReason: displaySettledResult?.reason ?? null,
            });
        }
        globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.restoreState.wait.finish', {
            reason,
            stage,
            settledReason: displaySettledResult?.reason ?? visibleSettleResult?.reason ?? null,
            requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
            currentFraction: typeof waitedState.currentFraction === 'number' ? safeRound(waitedState.currentFraction, 6) : null,
            currentSectionIndex: waitedState.sectionIndex ?? null,
            locationCurrent: waitedState.locationCurrent ?? null,
            locationTotal: waitedState.locationTotal ?? null,
            locationUsable: restoreStateHasUsableLocation(waitedState),
            fractionSatisfied: restoreStateFractionSatisfied(waitedState),
            renderReady: document.documentElement?.dataset?.mnbReaderRenderReady === '1',
        });
        return waitedState;
    };
    const syntheticRestoreLocator = hasFractionalCompletion ? null : parseSyntheticRestoreLocator(cfi);
    const spineOnlyRestoreSectionIndex = !syntheticRestoreLocator && !hasFractionalCompletion
        ? parseSpineOnlyEpubCFI(cfi)
        : null;
    const hasPreciseCFI = typeof cfi === 'string'
        && cfi.length > 0
        && !syntheticRestoreLocator
        && !hasFractionalCompletion
        && !Number.isInteger(spineOnlyRestoreSectionIndex);
    const restoreLocatorKind = syntheticRestoreLocator
        ? 'synthetic'
        : (Number.isInteger(spineOnlyRestoreSectionIndex) ? 'spine-cfi' : (hasPreciseCFI ? 'cfi' : (hasFractionalCompletion ? 'fraction' : 'none')));
    globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.normalizedRestore', {
        restoreLocatorKind,
        cfiLength: typeof cfi === 'string' ? cfi.length : 0,
        requestedFraction: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
        hasFractionalCompletion,
        syntheticSectionIndex: syntheticRestoreLocator?.sectionIndex ?? null,
        syntheticLocalPage: syntheticRestoreLocator?.localSectionIndex ?? null,
        syntheticRendererTotal: syntheticRestoreLocator?.rendererTotal ?? null,
        spineSectionIndex: spineOnlyRestoreSectionIndex ?? null,
        hasPreciseCFI,
        hasSpineOnlyCFI: Number.isInteger(spineOnlyRestoreSectionIndex),
        requestedDisplayPercent: Number.isFinite(fractionalCompletion) ? roundedDisplayPercent(fractionalCompletion) : null,
    });
    globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.start', {
        restoreLocatorKind,
        cfiLength: typeof cfi === 'string' ? cfi.length : 0,
        requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
        syntheticSectionIndex: syntheticRestoreLocator?.sectionIndex ?? null,
        syntheticLocalPage: syntheticRestoreLocator?.localSectionIndex ?? null,
        syntheticRendererTotal: syntheticRestoreLocator?.rendererTotal ?? null,
        spineSectionIndex: spineOnlyRestoreSectionIndex ?? null,
        initialRestoreHandled: !!globalThis.__manabiInitialRestoreHandled,
        hasLoadedLastPosition: globalThis.reader?.hasLoadedLastPosition === true,
        restoreInProgress: globalThis.__manabiRestoreInProgress === true,
    });
    let shouldKeepRestoreSaveGuard = false;
    const releaseDispatchedNavigation = (reason, {
        markReadyReason = null,
    } = {}) => {
        globalThis.__manabiRestoreInProgress = false;
        globalThis.reader.completeLastPositionLoad(reason);
        globalThis.__manabiSuppressNextRestoreRelocateSave = true;
        globalThis.__manabiRequireUserInputBeforePositionSave = true;
        shouldKeepRestoreSaveGuard = true;
        const visibleSettleResult = markReadyReason
            ? globalThis.reader?.settleInitialDisplayFromVisibleContent?.(`${markReadyReason}.visibleContent`)
            : null;
        if (markReadyReason && visibleSettleResult?.settled === true) {
            clearInitialRestoreRenderReadyGate(markReadyReason);
            markReaderRenderReady(markReadyReason);
        }
        globalThis.reader?.setLoadingIndicator?.(false, reason);
    };
    const clearDispatchedNavigationLoading = (reason) => {
        globalThis.reader?.setLoadingIndicator?.(false, reason);
    };
    const reconcileRestoreFractionIfNeeded = async (restoreState, reason, stageOnReconcile) => {
        if (!hasFractionalCompletion) {
            return;
        }
        const hasCurrentFraction = typeof restoreState?.currentFraction === 'number';
        const delta = hasCurrentFraction
            ? Math.abs(restoreState.currentFraction - fractionalCompletion)
            : Number.POSITIVE_INFINITY;
        const requestedDisplayPercent = roundedDisplayPercent(fractionalCompletion);
        const landedDisplayPercent = hasCurrentFraction
            ? roundedDisplayPercent(restoreState.currentFraction)
            : null;
        const displayPercentChanged = requestedDisplayPercent != null
            && landedDisplayPercent != null
            && requestedDisplayPercent !== landedDisplayPercent;
        if (hasCurrentFraction && delta <= 0.003 && !displayPercentChanged) {
            return;
        }
        const rendererPageCurrent = globalThis.reader?.navHUD?.rendererPageSnapshot?.current ?? null;
        const rendererPageTotal = globalThis.reader?.navHUD?.rendererPageSnapshot?.total ?? null;
        const targetRendererPage = typeof rendererPageTotal === 'number' && rendererPageTotal > 1
            ? Math.max(1, Math.min(rendererPageTotal, Math.round(fractionalCompletion * (rendererPageTotal - 1)) + 1))
            : null;
        if (
            typeof rendererPageCurrent === 'number'
            && typeof targetRendererPage === 'number'
            && rendererPageCurrent === targetRendererPage
        ) {
            return;
        }
        await runRestoreNavigation({
            source: 'restore.reconcile',
            reason,
            target: 'view.goToFraction',
            fraction: fractionalCompletion,
            stageOnReconcile,
        }, () => globalThis.reader.view.goToFraction(fractionalCompletion), {
            throwOnError: false,
        });
        await waitForFrames(2);
        const reconciledState = captureRestoreState(stageOnReconcile, {
            drift: Number.isFinite(delta) ? safeRound(delta, 6) : null,
            missingCurrentFraction: !hasCurrentFraction,
        });
        return waitForRestoreStateIfNeeded(
            reconciledState,
            `restore.reconcile.${reason}`,
            stageOnReconcile,
            { requireFractionSatisfied: true },
        );
    };
    try {
        let syntheticDisplaySettledForRestore = false;
        const initialRestoreHandled = globalThis.__manabiInitialRestoreHandled ?? null;
        const hasExplicitRestoreTarget = !!syntheticRestoreLocator
            || hasFractionalCompletion
            || hasPreciseCFI
            || Number.isInteger(spineOnlyRestoreSectionIndex);
        globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.initialRestoreStaleCheck', {
            hasInitialRestoreHandled: !!initialRestoreHandled,
            hasExplicitRestoreTarget,
            willConsiderStaleNativeCall: !!initialRestoreHandled && !hasExplicitRestoreTarget,
            restoreLocatorKind,
            hasReaderContent: !!document.querySelector?.('foliate-view'),
        });
        if (
            initialRestoreHandled
            && !hasExplicitRestoreTarget
            && document.querySelector?.('foliate-view')
            && finalizeInitialRestoreHandledWithoutNativeRestore('loadLastPosition.initialRestoreStaleNativeCall')
        ) {
            shouldKeepRestoreSaveGuard = true;
            globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.return', {
                path: 'initialRestoreStaleNativeCall',
                restoreLocatorKind,
                handledSectionIndex: initialRestoreHandled.sectionIndex ?? null,
                handledFraction: Number.isFinite(initialRestoreHandled.fractionalCompletion) ? safeRound(initialRestoreHandled.fractionalCompletion, 6) : null,
            });
            return;
        }
        const initialRestoreCfiMatches = typeof cfi === 'string'
            && cfi.length > 0
            && initialRestoreHandled?.cfi === cfi;
        const initialRestoreFractionMatches = !hasFractionalCompletion
            || (
                Number.isFinite(initialRestoreHandled?.fractionalCompletion)
                && Math.abs(initialRestoreHandled.fractionalCompletion - fractionalCompletion) <= 0.003
            );
        const initialState = initialRestoreHandled
            ? captureRestoreState('initial-restore-already-handled', {
                sectionIndex: initialRestoreHandled.sectionIndex ?? null,
            })
            : null;
        const initialRestoreCurrentFractionMatches = !hasFractionalCompletion
            || (
                typeof initialState?.currentFraction === 'number'
                && Math.abs(initialState.currentFraction - fractionalCompletion) <= 0.003
            );
        const initialRestoreHandledFractionDelta = hasFractionalCompletion && Number.isFinite(initialRestoreHandled?.fractionalCompletion)
            ? Math.abs(initialRestoreHandled.fractionalCompletion - fractionalCompletion)
            : null;
        const initialRestoreCurrentFractionDelta = hasFractionalCompletion && typeof initialState?.currentFraction === 'number'
            ? Math.abs(initialState.currentFraction - fractionalCompletion)
            : null;
        globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.initialRestoreHandledCheck', {
            hasInitialRestoreHandled: !!initialRestoreHandled,
            hasExplicitRestoreTarget,
            cfiMatches: initialRestoreCfiMatches,
            fractionMatches: initialRestoreFractionMatches,
            currentFractionMatches: initialRestoreCurrentFractionMatches,
            handledFraction: Number.isFinite(initialRestoreHandled?.fractionalCompletion) ? safeRound(initialRestoreHandled.fractionalCompletion, 6) : null,
            currentFraction: typeof initialState?.currentFraction === 'number' ? safeRound(initialState.currentFraction, 6) : null,
            requestedFraction: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
            handledFractionDelta: initialRestoreHandledFractionDelta != null ? safeRound(initialRestoreHandledFractionDelta, 6) : null,
            currentFractionDelta: initialRestoreCurrentFractionDelta != null ? safeRound(initialRestoreCurrentFractionDelta, 6) : null,
            currentSectionIndex: initialState?.sectionIndex ?? null,
            handledSectionIndex: initialRestoreHandled?.sectionIndex ?? null,
        });
        if (
            initialRestoreHandled
            && initialRestoreCfiMatches
            && initialRestoreFractionMatches
            && initialRestoreCurrentFractionMatches
        ) {
            globalThis.reader.completeLastPositionLoad('initial-restore-already-handled');
            globalThis.__manabiSuppressNextRestoreRelocateSave = true;
            globalThis.__manabiRequireUserInputBeforePositionSave = true;
            shouldKeepRestoreSaveGuard = true;
            const visibleSettleResult = globalThis.reader.settleInitialDisplayFromVisibleContent?.('loadLastPosition.initialRestoreAlreadyHandled.visibleContent');
            if (visibleSettleResult?.settled === true) {
                clearInitialRestoreRenderReadyGate('loadLastPosition.initialRestoreAlreadyHandled');
                markReaderRenderReady('loadLastPosition.initialRestoreAlreadyHandled');
            }
            globalThis.reader?.maybeFlashInitialForwardSideNavChevron?.(initialState);
            globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.return', {
                path: 'initialRestoreAlreadyHandled',
                restoreLocatorKind,
                handledSectionIndex: initialRestoreHandled.sectionIndex ?? null,
                handledFraction: Number.isFinite(initialRestoreHandled.fractionalCompletion) ? safeRound(initialRestoreHandled.fractionalCompletion, 6) : null,
                currentFraction: typeof initialState?.currentFraction === 'number' ? safeRound(initialState.currentFraction, 6) : null,
                currentSectionIndex: initialState?.sectionIndex ?? null,
            });
            return;
        }
        if (syntheticRestoreLocator) {
            globalThis.__manabiSuppressNextRestoreRelocateSave = true;
            globalThis.__manabiRequireUserInputBeforePositionSave = true;
            shouldKeepRestoreSaveGuard = true;
            const navigationResult = await runRestoreNavigation({
                source: 'restore.synthetic-locator',
                target: 'renderer.goTo',
                sectionIndex: syntheticRestoreLocator.sectionIndex,
                localPage: syntheticRestoreLocator.localSectionIndex,
                rendererTotal: syntheticRestoreLocator.rendererTotal,
                fraction: hasFractionalCompletion ? fractionalCompletion : null,
            }, () => globalThis.reader.view.renderer.goTo?.({
                index: syntheticRestoreLocator.sectionIndex,
                localPage: syntheticRestoreLocator.localSectionIndex,
            }), {
                throwOnError: false,
            });
            if (navigationResult?.ok !== true) {
                throw navigationResult?.error ?? new Error('Synthetic restore navigation failed');
            }
            await waitForPaintAfterNavigation();
            const visibleSettleResult = globalThis.reader.settleInitialDisplayFromVisibleContent?.('loadLastPosition.syntheticNavigationSettled');
            syntheticDisplaySettledForRestore = visibleSettleResult?.settled === true;
            releaseDispatchedNavigation('loadLastPosition.syntheticNavigation.release', {
                markReadyReason: 'loadLastPosition.syntheticNavigationSettled',
            });
            const syntheticState = captureRestoreState('after-synthetic-locator', {
                sectionIndex: syntheticRestoreLocator.sectionIndex,
                localSectionIndex: syntheticRestoreLocator.localSectionIndex,
                rendererTotal: syntheticRestoreLocator.rendererTotal,
                navigationOk: syntheticDisplaySettledForRestore,
                navigationPending: false,
            });
            globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.path.finish', {
                path: 'synthetic',
                navigationOk: syntheticDisplaySettledForRestore,
                requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
                currentFraction: typeof syntheticState.currentFraction === 'number' ? safeRound(syntheticState.currentFraction, 6) : null,
                currentSectionIndex: syntheticState.sectionIndex ?? null,
                locationCurrent: syntheticState.locationCurrent ?? null,
                locationTotal: syntheticState.locationTotal ?? null,
            });
        } else if (Number.isInteger(spineOnlyRestoreSectionIndex)) {
            globalThis.__manabiSuppressNextRestoreRelocateSave = true;
            globalThis.__manabiRequireUserInputBeforePositionSave = true;
            shouldKeepRestoreSaveGuard = true;
            const navigationResult = await runRestoreNavigation({
                source: hasFractionalCompletion ? 'restore.spine-cfi-fraction' : 'restore.spine-cfi',
                target: hasFractionalCompletion ? 'view.goToFraction' : 'renderer.goTo',
                sectionIndex: spineOnlyRestoreSectionIndex,
                cfiLength: typeof cfi === 'string' ? cfi.length : 0,
                fraction: hasFractionalCompletion ? fractionalCompletion : null,
            }, async () => {
                if (hasFractionalCompletion) {
                    return globalThis.reader.view.goToFraction(fractionalCompletion);
                }
                return globalThis.reader.view.renderer.goTo?.({
                    index: spineOnlyRestoreSectionIndex,
                });
            }, {
                throwOnError: false,
            });
            if (navigationResult?.ok !== true) {
                throw navigationResult?.error ?? new Error('Spine restore navigation failed');
            }
            await waitForPaintAfterNavigation();
            const spineState = await waitForRestoreStateIfNeeded(
                captureRestoreState('after-spine-cfi'),
                'restore.spine-cfi.after-navigation',
                'after-spine-cfi',
                { requireFractionSatisfied: hasFractionalCompletion },
            );
            const reconciledSpineState = await reconcileRestoreFractionIfNeeded(
                spineState,
                'spine-cfi-fraction-drift',
                'after-spine-cfi-fraction-reconcile',
            );
            const finalSpineState = await waitForRestoreStateIfNeeded(
                reconciledSpineState ?? captureRestoreState('after-spine-cfi-final'),
                'restore.spine-cfi.final',
                'after-spine-cfi-final',
                { requireFractionSatisfied: hasFractionalCompletion },
            );
            globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.path.finish', {
                path: 'spine-cfi',
                cfiLength: typeof cfi === 'string' ? cfi.length : 0,
                sectionIndex: spineOnlyRestoreSectionIndex,
                requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
                currentFraction: typeof finalSpineState.currentFraction === 'number' ? safeRound(finalSpineState.currentFraction, 6) : null,
                currentSectionIndex: finalSpineState.sectionIndex ?? null,
                locationCurrent: finalSpineState.locationCurrent ?? null,
                locationTotal: finalSpineState.locationTotal ?? null,
            });
        } else if (hasPreciseCFI) {
            globalThis.__manabiSuppressNextRestoreRelocateSave = true;
            globalThis.__manabiRequireUserInputBeforePositionSave = true;
            shouldKeepRestoreSaveGuard = true;
            const navigationResult = await runRestoreNavigation({
                source: 'restore.cfi',
                target: 'view.goTo',
                cfiLength: cfi.length,
                fraction: hasFractionalCompletion ? fractionalCompletion : null,
            }, () => globalThis.reader.view.goTo(cfi), {
                throwOnError: false,
            });
            if (navigationResult?.ok !== true) {
                const error = navigationResult?.error;
                console.error(error)
                globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.cfi.error', {
                    cfiLength: cfi.length,
                    spineSectionIndex: spineOnlyRestoreSectionIndex ?? null,
                    requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
                    error: error?.message || String(error),
                });
                throw error ?? new Error('CFI restore navigation failed');
            }
            await waitForPaintAfterNavigation();
            const cfiState = await waitForRestoreStateIfNeeded(
                captureRestoreState('after-cfi'),
                'restore.cfi.after-navigation',
                'after-cfi',
                { requireFractionSatisfied: hasFractionalCompletion },
            );
            const reconciledCfiState = await reconcileRestoreFractionIfNeeded(
                cfiState,
                'cfi-fraction-drift',
                'after-cfi-fraction-reconcile',
            );
            const finalCfiState = await waitForRestoreStateIfNeeded(
                reconciledCfiState ?? captureRestoreState('after-cfi-final'),
                'restore.cfi.final',
                'after-cfi-final',
                { requireFractionSatisfied: hasFractionalCompletion },
            );
            globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.path.finish', {
                path: 'cfi',
                cfiLength: cfi.length,
                requestedFraction: hasFractionalCompletion ? safeRound(fractionalCompletion, 6) : null,
                currentFraction: typeof finalCfiState.currentFraction === 'number' ? safeRound(finalCfiState.currentFraction, 6) : null,
                currentSectionIndex: finalCfiState.sectionIndex ?? null,
                locationCurrent: finalCfiState.locationCurrent ?? null,
                locationTotal: finalCfiState.locationTotal ?? null,
            });
        } else if (hasFractionalCompletion) {
            try {
                globalThis.__manabiSuppressNextRestoreRelocateSave = true;
                globalThis.__manabiRequireUserInputBeforePositionSave = true;
                shouldKeepRestoreSaveGuard = true;
                await runRestoreNavigation({
                    source: 'restore.fraction',
                    target: 'view.goToFraction',
                    fraction: fractionalCompletion,
                }, () => globalThis.reader.view.goToFraction(fractionalCompletion));
                await waitForPaintAfterNavigation();
                const fractionState = await waitForRestoreStateIfNeeded(
                    captureRestoreState('after-fraction'),
                    'restore.fraction.after-navigation',
                    'after-fraction',
                    { requireFractionSatisfied: true },
                );
                globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.path.finish', {
                    path: 'fraction',
                    requestedFraction: safeRound(fractionalCompletion, 6),
                    currentFraction: typeof fractionState.currentFraction === 'number' ? safeRound(fractionState.currentFraction, 6) : null,
                    currentSectionIndex: fractionState.sectionIndex ?? null,
                    locationCurrent: fractionState.locationCurrent ?? null,
                    locationTotal: fractionState.locationTotal ?? null,
                });
            } catch (error) {
                const fallbackState = captureRestoreState('after-fraction-restore-skipped');
                globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.path.error', {
                    path: 'fraction',
                    error: error?.message || String(error),
                    currentFraction: typeof fallbackState.currentFraction === 'number' ? safeRound(fallbackState.currentFraction, 6) : null,
                    currentSectionIndex: fallbackState.sectionIndex ?? null,
                });
                throw error;
            }
        } else {
            await globalThis.reader?.displayInitialSection?.('loadLastPosition.noRestoreTarget');
            const defaultState = captureRestoreState('after-no-restore-target');
            globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.path.finish', {
                path: 'default',
                currentFraction: typeof defaultState.currentFraction === 'number' ? safeRound(defaultState.currentFraction, 6) : null,
                currentSectionIndex: defaultState.sectionIndex ?? null,
                locationCurrent: defaultState.locationCurrent ?? null,
                locationTotal: defaultState.locationTotal ?? null,
            });
        }
        const doneState = await waitForRestoreStateIfNeeded(
            captureRestoreState('done'),
            'loadLastPosition.done',
            'done',
            { requireFractionSatisfied: hasFractionalCompletion },
        );
        const doneHasUsableLocation = restoreStateHasUsableLocation(doneState);
        const doneFractionSatisfied = restoreStateFractionSatisfied(doneState);
        globalThis.reader.hasLoadedLastPosition = !hasExplicitRestoreTarget || doneHasUsableLocation;
        const doneVisibleSettleResult = globalThis.reader.settleInitialDisplayFromVisibleContent?.('loadLastPosition.done.visibleContent');
        if (
            globalThis.reader.hasLoadedLastPosition
            && doneVisibleSettleResult?.settled === true
            && (!syntheticRestoreLocator || syntheticDisplaySettledForRestore)
        ) {
            clearInitialRestoreRenderReadyGate('loadLastPosition.done');
            markReaderRenderReady('loadLastPosition.done');
        }
        if (globalThis.reader.hasLoadedLastPosition) {
            globalThis.reader.refreshNativeMarkReadState?.('load-last-position-done');
        }
        const restoredExplicitPosition = doneHasUsableLocation && doneFractionSatisfied && (
            !!syntheticRestoreLocator
            || Number.isInteger(spineOnlyRestoreSectionIndex)
            || hasPreciseCFI
            || hasFractionalCompletion
        );
        if (restoredExplicitPosition) {
            globalThis.__manabiInitialRestoreHandled = {
                cfi: typeof cfi === 'string' ? cfi : '',
                fractionalCompletion: typeof doneState.currentFraction === 'number'
                    ? doneState.currentFraction
                    : (Number.isFinite(fractionalCompletion) ? fractionalCompletion : null),
                sectionIndex: doneState.sectionIndex ?? null,
                localSectionIndex: syntheticRestoreLocator?.localSectionIndex ?? null,
                rendererTotal: syntheticRestoreLocator?.rendererTotal ?? null,
                fractionalAnchorSuppressed: !!syntheticRestoreLocator,
                handledAtMs: Date.now(),
                source: 'loadLastPosition',
            };
        }
        if (hasExplicitRestoreTarget) {
            manabiPublishInitialRestoreResult(manabiCreateInitialRestoreResult({
                requestID: null,
                terminalState: restoredExplicitPosition ? 'satisfied' : 'failed',
                requestedLocator: restoreLocatorKind,
                resolvedLocator: restoreLocatorKind,
                requestedFraction: Number.isFinite(fractionalCompletion) ? fractionalCompletion : null,
                requestedCFI: cfi,
                location: {
                    fraction: typeof doneState.currentFraction === 'number' ? doneState.currentFraction : null,
                    sectionIndex: doneState.sectionIndex ?? null,
                },
                handledFractionalCompletion: restoredExplicitPosition
                    ? (typeof doneState.currentFraction === 'number'
                        ? doneState.currentFraction
                        : (Number.isFinite(fractionalCompletion) ? fractionalCompletion : null))
                    : null,
                navigationOk: restoredExplicitPosition,
                error: null,
                reason: 'loadLastPosition',
            }));
        }
        globalThis.reader?.maybeFlashInitialForwardSideNavChevron?.(doneState);
        globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.done', {
            restoreLocatorKind,
            requestedFraction: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
            currentFraction: typeof doneState.currentFraction === 'number' ? safeRound(doneState.currentFraction, 6) : null,
            currentSectionIndex: doneState.sectionIndex ?? null,
            locationCurrent: doneState.locationCurrent ?? null,
            locationTotal: doneState.locationTotal ?? null,
            hasLoadedLastPosition: globalThis.reader?.hasLoadedLastPosition === true,
            locationUsable: doneHasUsableLocation,
            fractionSatisfied: doneFractionSatisfied,
            updatedInitialRestoreHandled: restoredExplicitPosition,
            suppressNextSave: globalThis.__manabiSuppressNextRestoreRelocateSave === true,
            requireUserInputBeforeSave: globalThis.__manabiRequireUserInputBeforePositionSave === true,
        });
        postLandscapeInsetRestoreProbe('done', doneState, {
            hasCFI: typeof cfi === 'string' && cfi.length > 0,
            requestedFraction: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
        });
    } catch (error) {
        console.error(error);
        if (globalThis.reader) {
            globalThis.reader.hasLoadedLastPosition = false;
        }
        // A failed attempt must not replace the last locator that was already
        // proven valid. Native persistence remains untouched as well.
        globalThis.__manabiInitialRestoreHandled = previouslyHandledInitialRestore;
        const failedState = captureRestoreState('failed');
        manabiPublishInitialRestoreResult(manabiCreateInitialRestoreResult({
            requestID: null,
            terminalState: 'failed',
            requestedLocator: restoreLocatorKind,
            resolvedLocator: null,
            requestedFraction: Number.isFinite(fractionalCompletion) ? fractionalCompletion : null,
            requestedCFI: cfi,
            location: {
                fraction: typeof failedState.currentFraction === 'number' ? failedState.currentFraction : null,
                sectionIndex: failedState.sectionIndex ?? null,
            },
            navigationOk: false,
            error: error?.message || String(error),
            reason: 'loadLastPosition.failed',
        }));
        finishInitialRestoreRenderReadyGateWithTerminalResult('loadLastPosition.failed');
        throw error;
    } finally {
        globalThis.__manabiRestoreInProgress = false;
        if (globalThis.reader?.hasLoadedLastPosition === true) {
            globalThis.reader.completeLastPositionLoad('load-last-position-finally');
        }
        globalThis.reader?.setLoadingIndicator?.(false, 'loadLastPosition.finally');
        if (globalThis.reader?.hasLoadedLastPosition === true) {
            globalThis.reader.refreshNativeMarkReadState?.('load-last-position-finally');
        }
        if (!shouldKeepRestoreSaveGuard) {
            globalThis.__manabiSuppressNextRestoreRelocateSave = false;
        }
        globalThis.__manabiRequireUserInputBeforePositionSave = true;
        globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.finally', {
            restoreLocatorKind,
            hasLoadedLastPosition: globalThis.reader?.hasLoadedLastPosition === true,
            restoreInProgress: globalThis.__manabiRestoreInProgress === true,
            suppressNextSave: globalThis.__manabiSuppressNextRestoreRelocateSave === true,
            requireUserInputBeforeSave: globalThis.__manabiRequireUserInputBeforePositionSave === true,
        });
    }
}

window.refreshBookReadingProgress = async (articleReadingProgress) => {
    if (!globalThis.reader) {
        return;
    }
    const normalizedProgress = normalizeArticleReadingProgress(articleReadingProgress);
    globalThis.reader.applyBookReadingProgress(articleReadingProgress, 'native-refresh');
    await globalThis.reader.updateNavButtons();
}

window.manabiToggleReaderTableOfContents = () => {
    globalThis.reader?.toggleTableOfContents?.();
}

window.manabiHandlePhysicalArrowKey = async (direction) => {
    return await globalThis.reader?.handlePhysicalArrowKey?.(direction) ?? false;
}

window.manabi_performLookupNavigationPageTurn = async (request = {}) => {
    return await globalThis.reader?.performLookupNavigationPageTurn?.(request) ?? {
        opened: false,
        failureReason: 'missingReader',
    };
}

window.manabiGetReaderGoToSheetSnapshot = async () => {
    return await globalThis.reader?.buildGoToSheetSnapshot?.() ?? {
        isRTL: false,
        currentChapterHref: null,
        currentChapterTitle: null,
        currentPercent: null,
        chapters: [],
    };
}

window.manabiScheduleReaderPageGoTo = (pageNumber) => {
    markRestorePositionSaveUserInput('bridge.scheduleReaderPageGoTo');
    globalThis.reader?.scheduleGoToPageNumber?.(pageNumber);
}

window.manabiGoToReaderPage = async (pageNumber) => {
    markRestorePositionSaveUserInput('bridge.goToReaderPage');
    globalThis.reader?.navHUD?.requestExplicitRelocateHistoryMutation?.('bridge.goToReaderPage');
    return await globalThis.reader?.goToPageNumber?.(pageNumber, 'window.manabiGoToReaderPage');
}

window.manabiScheduleReaderLocationGoTo = (locationNumber) => {
    markRestorePositionSaveUserInput('bridge.scheduleReaderLocationGoTo');
    globalThis.reader?.scheduleGoToPageNumber?.(locationNumber);
}

window.manabiGoToReaderLocation = async (locationNumber) => {
    markRestorePositionSaveUserInput('bridge.goToReaderLocation');
    globalThis.reader?.navHUD?.requestExplicitRelocateHistoryMutation?.('bridge.goToReaderLocation');
    return await globalThis.reader?.goToLocationNumber?.(locationNumber, 'window.manabiGoToReaderLocation');
}

window.manabiGoToReaderPercent = async (percent) => {
    markRestorePositionSaveUserInput('bridge.goToReaderPercent');
    globalThis.reader?.navHUD?.requestExplicitRelocateHistoryMutation?.('bridge.goToReaderPercent');
    return await globalThis.reader?.goToPercent?.(percent, 'window.manabiGoToReaderPercent');
}

window.manabiGoToReaderHref = async (href) => {
    markRestorePositionSaveUserInput('bridge.goToReaderHref');
    globalThis.reader?.navHUD?.requestExplicitRelocateHistoryMutation?.('bridge.goToReaderHref');
    return await globalThis.reader?.goToHref?.(href, 'window.manabiGoToReaderHref');
}

window.manabiScheduleReaderFractionGoTo = (fraction) => {
    markRestorePositionSaveUserInput('bridge.scheduleReaderFractionGoTo');
    globalThis.reader?.scheduleGoToFraction?.(fraction);
}

window.manabiCancelScheduledReaderFractionGoTo = () => {
    globalThis.reader?.scheduleGoToFraction?.cancel?.();
    return true;
}

window.manabiBeginReaderProgressScrub = () => {
    markRestorePositionSaveUserInput('bridge.beginReaderProgressScrub');
    const navHUD = globalThis.reader?.navHUD;
    if (navHUD?.scrubSession?.active) {
        return true;
    }
    const originDescriptor = navHUD?.getCurrentLocationDescriptor?.() ?? null;
    navHUD?.beginProgressScrubSession?.(originDescriptor);
    return true;
}

window.manabiEndReaderProgressScrub = async (fraction, cancel = false) => {
    markRestorePositionSaveUserInput(cancel ? 'bridge.endReaderProgressScrub.cancel' : 'bridge.endReaderProgressScrub.commit');
    const navHUD = globalThis.reader?.navHUD;
    const view = globalThis.reader?.view;
    globalThis.reader?.scheduleGoToFraction?.cancel?.();
    const numericFraction = Number(fraction);
    const clampedFraction = Number.isFinite(numericFraction)
        ? Math.max(0, Math.min(1, numericFraction))
        : null;
    const finalDescriptor = clampedFraction != null
        ? (navHUD?._descriptorFromFraction?.(clampedFraction) ?? { fraction: clampedFraction })
        : (navHUD?.getCurrentLocationDescriptor?.() ?? null);
    const finalizeScrubSession = () => {
        navHUD?.endProgressScrubSession?.(finalDescriptor, {
            cancel: !!cancel,
            releaseFraction: clampedFraction,
        });
    };
    if (!cancel && Number.isFinite(clampedFraction) && view) {
        try {
            navHUD?.requestExplicitRelocateHistoryMutation?.('scrub-release');
            await runWithNavigationIntent({
                source: 'scrub-release',
                target: 'view.goToFraction',
                fraction: clampedFraction,
            }, () => view.goToFraction(clampedFraction));
            finalizeScrubSession();
        } catch (error) {
            finalizeScrubSession();
            console.error(error);
        }
    } else {
        finalizeScrubSession();
    }
    return true;
}

window.manabiTriggerReaderRelocateJump = async (direction) => {
    const navHUD = globalThis.reader?.navHUD;
    if (direction !== 'back' && direction !== 'forward') {
        return false;
    }
    await navHUD?._handleRelocateJump?.(direction);
    return true;
}

window.manabiScheduleReaderPercentGoTo = (percent) => {
    const numericPercent = Number(percent);
    if (!Number.isFinite(numericPercent)) {
        return;
    }
    markRestorePositionSaveUserInput('bridge.scheduleReaderPercentGoTo');
    globalThis.reader?.scheduleGoToFraction?.(numericPercent / 100);
}

window.manabiOpenReaderGoToSheet = (source = 'window.manabiOpenReaderGoToSheet') => {
    postOpenReaderGoToSheetRequest(source, null);
}

window.nextSection = async () => {
    const btn = globalThis.reader?.buttons?.next;
    if (btn && btn.offsetParent !== null && getComputedStyle(btn).visibility !== 'hidden') {
        btn.click();
    } else {
        await globalThis.reader?.view?.renderer?.nextSection?.();
    }
}

window.manabiReadAloudAdvanceToNextSection = async () => {
    const reader = globalThis.reader;
    const renderer = reader?.view?.renderer;
    const sections = reader?.view?.book?.sections;
    if (!renderer || !Array.isArray(sections)) return false;
    const beforeIndex = getPrimaryRendererContentIndex(renderer);
    if (!Number.isFinite(beforeIndex) || beforeIndex >= sections.length - 1) return false;
    await renderer.nextSection?.();
    for (let attempt = 0; attempt < 80; attempt += 1) {
        const afterIndex = getPrimaryRendererContentIndex(renderer);
        if (Number.isFinite(afterIndex) && afterIndex !== beforeIndex) return true;
        await new Promise((resolve) => setTimeout(resolve, 50));
    }
    return false;
}

window.manabi_markAllSectionsAsRead = async () => {
    return await globalThis.reader?.markAllSectionsAsRead?.() ?? 0;
}

window.manabi_buildMarkAllSectionsAsReadPayload = () => {
    return globalThis.reader?.buildMarkAllSectionsAsReadPayload?.() ?? null;
}

window.manabi_applyOptimisticMarkAllSectionsAsReadPayload = (payload) => {
    return globalThis.reader?.applyOptimisticMarkAllSectionsAsReadPayload?.(payload) ?? 0;
}

window.webkit.messageHandlers.ebookViewerInitialized.postMessage({})
