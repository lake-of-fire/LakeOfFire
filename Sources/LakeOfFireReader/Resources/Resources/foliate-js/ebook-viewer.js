import './view.js'
import {
createTOCView
} from './ui/tree.js'
import { NavigationHUD } from './ebook-viewer-nav.js'
import { processedSectionURLForHref } from './ebook-direct-section.js'
import { copyCustomReaderFontStyleToDocument } from './ebook-font-forwarding.js'
import { ebookProgressFractionForRelocate } from './ebook-reading-progress.js'
import {
    ebookSegmentIdentity,
    ebookSegmentIdentifierAliases,
} from './ebook-segment-identity.js'
import {
    ebookDocumentFrameIdentity,
    shouldPublishForDocumentFrame,
} from './ebook-document-frame-identity.js'
import {
    PAGE_TURN_MOVEMENT_DISPOSITION,
    observedPageTurnMovementDisposition,
    pageTurnMovementDisposition,
} from './page-turn-coordination.js'
import { beginNavigationIntent } from './navigation-intent.js'
import { beginOwnedElementOperation, finishOwnedElementOperation } from './owned-element-operation.js'
import { createOwnedAsyncCache } from './owned-async-cache.js'
import { resetReaderTransientState } from './reader-transient-state.js'
import {
    activeRendererContentsForLookup,
    getCurrentRendererDocument,
    getPrimaryRendererContent,
    getPrimaryRendererContentIndex,
} from './renderer-content.js'
import {
    advanceCurrentRendererSection,
    rendererNavigationAccepted,
    rendererNavigationInFlight,
} from './renderer-navigation.js'
import {
    LatestRestoreTransactionCoordinator,
    PendingInitialRestoreMailbox,
    isRestoreTransactionSupersededError,
    makeSyntheticRestoreLocator,
    makeRestoreTransactionSupersededError,
    parseSyntheticRestoreLocator,
    runAcceptedRestoreNavigation,
    commitAfterMatchingRestoreTransactionsSettle,
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
const manabiBlankNavigationMoveThreshold = 12;
const manabiSyntheticTouchMouseDistanceThreshold = 24;
const lastPositionRestoreCoordinator = new LatestRestoreTransactionCoordinator();

const resetRestoreTransactionGlobals = ({ clearHandled = false } = {}) => {
    globalThis.__manabiRequestedRestoreFraction = null;
    globalThis.__manabiRestoreInProgress = false;
    globalThis.__manabiSuppressNextRestoreRelocateSave = false;
    globalThis.__manabiRequireUserInputBeforePositionSave = false;
    if (clearHandled) {
        globalThis.__manabiInitialRestoreHandled = null;
    }
};
const manabiEventScreenPoint = event => {
    const point = event?.changedTouches?.[0] ?? event?.touches?.[0] ?? event;
    if (!point) return null;
    return {
        x: point.screenX ?? point.clientX ?? null,
        y: point.screenY ?? point.clientY ?? null,
    };
};

const manabiSegmentSidecarParserVersion = 10;
const manabiSegmentSidecarNativeVersion = Number.isSafeInteger(
    globalThis.manabi_compactSegmentSidecarSchemaVersion
)
    ? globalThis.manabi_compactSegmentSidecarSchemaVersion
    : null;
const manabiSegmentSidecarSchemaIsCompatible =
    manabiSegmentSidecarNativeVersion === manabiSegmentSidecarParserVersion;
const manabiCanParseCompactSegmentSidecar = (payload) => (
    manabiSegmentSidecarSchemaIsCompatible
    && payload?.v === manabiSegmentSidecarParserVersion
    && !!payload?.t
    && Array.isArray(payload?.s)
);
globalThis.manabi_segmentSidecarSchemaDiagnostics = Object.freeze({
    parserVersion: manabiSegmentSidecarParserVersion,
    nativeVersion: manabiSegmentSidecarNativeVersion,
    nativeSchemaIsCompatible: manabiSegmentSidecarSchemaIsCompatible,
    acceptsPayload: manabiCanParseCompactSegmentSidecar,
});

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
        if (!manabiCanParseCompactSegmentSidecar(payload)) {
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

// The current compact schema derives examples from sidecar tuples on demand. This avoids
// serializing the same sentence facts twice and keeps sentence HTML assembly off the initial
// render path.
const manabiSentenceArchiveEntryFromSidecarSegments = (segments) => {
    let text = '';
    const sentenceJMDictIDs = [];
    const sentenceJMDictIDSet = new Set();
    const vocabularyCandidateGroups = [];
    const archiveSegments = [];
    for (const segment of segments) {
        text += segment.x || segment.s || segment.ns || '';
        const jmdictEntryIDs = manabiSidecarNumberArray(segment.j);
        const jmnedictEntryIDs = manabiSidecarNumberArray(segment.n);
        const primaryEntryID = jmdictEntryIDs[0];
        if (Number.isFinite(primaryEntryID) && !sentenceJMDictIDSet.has(primaryEntryID)) {
            sentenceJMDictIDSet.add(primaryEntryID);
            sentenceJMDictIDs.push(primaryEntryID);
        }
        if (jmdictEntryIDs.length > 0 || jmnedictEntryIDs.length > 0) {
            vocabularyCandidateGroups.push({
                jmdictEntryIds: jmdictEntryIDs,
                // Preserve both typed alternative sets. Primary selection is a
                // native policy; the sidecar must not erase dictionary identity.
                jmnedictEntryIds: jmnedictEntryIDs,
            });
        }
        const segmentIdentifier = segment.sid || '';
        if (segmentIdentifier) {
            archiveSegments.push({
                jmdictEntryIds: jmdictEntryIDs,
                jmnedictEntryIds: jmnedictEntryIDs,
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
        vocabularyCandidateGroups,
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

const clearInitialRestoreRenderReadyGate = (_reason) => {
    if (globalThis.__manabiInitialRestoreRenderReadyGate?.active !== true) {
        return false;
    }
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
    if (html?.dataset) {
        html.dataset.mnbReaderRenderReady = '1';
    }
    if (body?.dataset) {
        body.dataset.mnbReaderRenderReady = '1';
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

const readerDocumentStartedAtMs = () => Number.isFinite(globalThis.performance?.timeOrigin)
    ? globalThis.performance.timeOrigin
    : null;

window.onerror = function(msg, source, lineno, colno, error) {
    if (shouldIgnoreWindowError(msg)) return true;
    window.webkit?.messageHandlers?.readerOnError?.postMessage?.({
        message: msg,
        source: source,
        lineno: lineno,
        colno: colno,
        error: String(error),
        documentStartedAtMs: readerDocumentStartedAtMs(),
    });
};

window.onunhandledrejection = function(event) {
    window.webkit?.messageHandlers?.readerOnError?.postMessage?.({
        message: event.reason?.message ?? "Unhandled rejection",
        source: window.location.href,
        lineno: null,
        colno: null,
        error: event.reason?.stack ?? String(event.reason),
        documentStartedAtMs: readerDocumentStartedAtMs(),
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
            error: e.error?.stack || String(e.error || e),
            documentStartedAtMs: readerDocumentStartedAtMs(),
        });
    });
    root.addEventListener('unhandledrejection', e => {
        window.webkit?.messageHandlers?.readerOnError?.postMessage?.({
            message: e.reason?.message || 'Shadow-DOM unhandled rejection',
            source: window.location.href,
            lineno: 0,
            colno: 0,
            error: e.reason?.stack || String(e.reason),
            documentStartedAtMs: readerDocumentStartedAtMs(),
        });
    });
}

const roundedDisplayPercent = value => {
    if (typeof value !== 'number' || !Number.isFinite(value)) {
        return null;
    }
    return Math.round(Math.max(0, Math.min(1, value)) * 100);
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
            documentStartedAtMs: Number.isFinite(view.performance?.timeOrigin)
                ? view.performance.timeOrigin
                : null,
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

const adaptReplaceTextHTMLForMode = (html, { href }) => {
    const hasSentences = typeof html === 'string' && /<m-s\b/i.test(html);
    const hasSegments = typeof html === 'string' && /<m-m\b/i.test(html);
    return injectBodyDatasetAttributes(html, {
        'data-mnb-source-href': href,
        'data-mnb-has-sentences': hasSentences ? 'true' : null,
        'data-mnb-has-segments': hasSegments ? 'true' : null,
    });
};

const makeReplaceText = ({
    allowForegroundHTML = true,
    isCurrent = () => true,
} = {}) => {
    const cache = createOwnedAsyncCache({
        limit: REPLACE_TEXT_RESULT_CACHE_LIMIT,
        shouldRemember: result => result?.isAuthoritativelyProcessed === true,
    });
    let destroyed = false;
    const isActive = () => !destroyed && isCurrent();
    const replaceText = async (href, text, mediaType) => {
        if (!isActive()) return null;
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
        const run = async (signal) => {
            if (!isActive()) return null;
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
                signal: signal ?? undefined,
            };
            try {
                const fetchStartedAt = performanceNowMs();
                const response = await fetch(requestURL, requestOptions);
                if (!isActive()) return null;
                const responseHeadersElapsedMs = performanceNowMs() - fetchStartedAt;
                manabiTimelineMeasure('processText.fetchHeaders', fetchStartedAt, {
                    requestID: processTextRequestID,
                    href,
                    status: response?.status ?? null,
                    transport,
                }, 50);
                if (!response.ok) {
                    throw new Error(`HTTP error, status = ${response.status}`);
                }
                const textStartedAt = performanceNowMs();
                const html = await response.text();
                if (!isActive()) return null;
                const responseTextElapsedMs = performanceNowMs() - textStartedAt;
                const responseTextLength = html.length;
                const nativeCacheOutcome = response.headers?.get?.('x-manabi-process-cache') || null;
                const isAuthoritativelyProcessed = response.headers?.get?.('x-manabi-processing-authoritative') !== 'false';
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
                return {
                    html,
                    isAuthoritativelyProcessed,
                };
            } finally {
                globalThis.__manabiInflightReplaceTextCount = Math.max(0, (globalThis.__manabiInflightReplaceTextCount ?? 1) - 1);
                globalThis.__manabiInflightLiveReplaceTextCount = Math.max(0, (globalThis.__manabiInflightLiveReplaceTextCount ?? 1) - 1);
            }
        };

        let neutralHTML;
        try {
            const processedResult = await cache.getOrCreate(cacheKey, run);
            neutralHTML = processedResult?.html ?? null;
        } catch (error) {
            if (!isActive()) return null;
            console.error("Error replacing text:", error);
            neutralHTML = text;
        }
        if (!isActive() || neutralHTML == null) return null;
        const html = adaptReplaceTextHTMLForMode(neutralHTML, { href });
        if (!isActive()) return null;
        window.manabi_recordLiveProcessedSection?.(href);
        return html;
    };
    replaceText.destroy = () => {
        if (destroyed) return false;
        destroyed = true;
        cache.clear();
        return true;
    };
    return replaceText;
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

const computeRawSectionWritingDirectionFromText = async (
    href,
    text,
    loadText,
    signal = null
) => {
    if (signal?.aborted || !text || typeof DOMParser !== 'function') return null;
    const doc = new DOMParser().parseFromString(text, 'application/xhtml+xml');
    if (!doc?.documentElement || doc.querySelector?.('parsererror')) return null;

    const cloneDoc = document.implementation.createHTMLDocument();
    const clonedHead = doc.head?.cloneNode?.(true) ?? cloneDoc.createElement('head');
    clonedHead.querySelectorAll?.('script')?.forEach?.(el => el.remove());
    const inlineWritingMode = [
        doc.body?.getAttribute?.('style') ?? '',
        doc.documentElement?.getAttribute?.('style') ?? '',
    ].map(style => style.match(/(?:^|;)\s*(?:-webkit-)?writing-mode\s*:\s*([^;]+)/i)?.[1]
        ?.trim?.().toLowerCase?.()
    ).find(mode => mode === 'vertical-rl' || mode === 'vertical-lr' || mode === 'horizontal-tb') ?? null;

    const blobURLs = [];
    let iframe = null;
    try {
        const stylesheetLinks = Array.from(clonedHead.querySelectorAll?.('link[rel="stylesheet"][href]') ?? []);
        for (const link of stylesheetLinks) {
            if (signal?.aborted) return null;
            const stylesheetHref = link.getAttribute('href');
            if (!stylesheetHref || /^(?:https?:|data:|blob:)/i.test(stylesheetHref)) continue;
            const resolvedHref = resolveEpubRelativePath(stylesheetHref, href);
            try {
                const css = await loadText?.(resolvedHref, { signal });
                if (signal?.aborted) return null;
                if (!css) continue;
                const stylesheetBlobURL = URL.createObjectURL(new Blob([css], { type: 'text/css' }));
                blobURLs.push(stylesheetBlobURL);
                link.href = stylesheetBlobURL;
            } catch (_error) {}
        }

        if (signal?.aborted) return null;
        const bodyClone = doc.body?.cloneNode?.(false) ?? cloneDoc.createElement('body');
        cloneDoc.head.replaceWith(clonedHead);
        cloneDoc.body.replaceWith(bodyClone);
        for (const { name, value } of Array.from(doc.documentElement?.attributes ?? [])) {
            cloneDoc.documentElement.setAttribute(name, value);
        }

        iframe = document.createElement('iframe');
        iframe.style.cssText = 'position:fixed;visibility:hidden;width:0;height:0;border:0;contain:strict;';
        document.documentElement.appendChild(iframe);
        const documentBlobURL = URL.createObjectURL(new Blob(
            ['<!doctype html>', cloneDoc.documentElement.outerHTML],
            { type: 'text/html' },
        ));
        blobURLs.push(documentBlobURL);

        const loaded = await new Promise(resolve => {
            let settled = false;
            const finish = value => {
                if (settled) return;
                settled = true;
                signal?.removeEventListener?.('abort', onAbort);
                resolve(value);
            };
            const onAbort = () => finish(false);
            iframe.addEventListener('load', () => finish(true), { once: true });
            iframe.addEventListener('error', () => finish(false), { once: true });
            signal?.addEventListener?.('abort', onAbort, { once: true });
            if (signal?.aborted) {
                finish(false);
                return;
            }
            iframe.src = documentBlobURL;
        });
        if (!loaded || signal?.aborted) return null;
        await new Promise(resolve => scheduleNextFrame(resolve));
        if (signal?.aborted) return null;
        const probeDoc = iframe.contentDocument;
        const bodyStyle = iframe.contentWindow?.getComputedStyle?.(probeDoc?.body);
        const rootStyle = iframe.contentWindow?.getComputedStyle?.(probeDoc?.documentElement);
        const writingMode = (
            normalizedComputedWritingMode(bodyStyle)
            || normalizedComputedWritingMode(rootStyle)
            || ''
        );
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
        if (inlineWritingMode === 'vertical-rl' || inlineWritingMode === 'vertical-lr') {
            return { direction: 'vertical', writingMode: inlineWritingMode };
        }
        if (inlineWritingMode === 'horizontal-tb') {
            return { direction: 'horizontal', writingMode: 'horizontal-tb' };
        }
        return null;
    } finally {
        iframe?.remove?.();
        for (const url of blobURLs) {
            try { URL.revokeObjectURL(url); } catch (_error) {}
        }
    }
};

const computeRawSectionWritingDirection = async (
    sourceURL,
    href,
    loadText = null,
    cache = createOwnedAsyncCache(),
    isCurrent = () => true
) => {
    const cacheKey = `${sourceURL || ''}|${href || ''}`;
    return cache.getOrCreate(cacheKey, signal => new Promise((resolve) => {
        if (signal?.aborted || !isCurrent() || !sourceURL || !href) {
            resolve(null);
            return;
        }
        const iframe = document.createElement('iframe');
        const rawProbeController = typeof AbortController === 'function'
            ? new AbortController()
            : null;
        let settled = false;
        let timeout = null;
        const onAbort = () => finish(null);
        const finish = (value) => {
            if (settled) return;
            settled = true;
            if (timeout) clearTimeout(timeout);
            signal?.removeEventListener?.('abort', onAbort);
            try { rawProbeController?.abort(); } catch (_error) {}
            iframe.remove();
            resolve(isCurrent() && !signal?.aborted ? value : null);
        };
        signal?.addEventListener?.('abort', onAbort, { once: true });
        if (signal?.aborted) {
            finish(null);
            return;
        }
        timeout = setTimeout(() => finish(null), 1200);
        const finishWithRawText = async () => {
            if (!isCurrent() || signal?.aborted || typeof loadText !== 'function') return false;
            try {
                const rawText = await loadText(href, { signal: rawProbeController?.signal ?? signal });
                if (!isCurrent() || signal?.aborted) {
                    finish(null);
                    return true;
                }
                const rawDirection = await computeRawSectionWritingDirectionFromText(
                    href,
                    rawText,
                    loadText,
                    rawProbeController?.signal ?? signal
                );
                if (!isCurrent() || signal?.aborted) {
                    finish(null);
                    return true;
                }
                if (rawDirection) {
                    finish(rawDirection);
                    return true;
                }
            } catch (_error) {
            }
            return false;
        };
        const startURLProbe = () => {
            if (settled || signal?.aborted || !isCurrent()) {
                finish(null);
                return;
            }
            iframe.style.cssText = 'position:absolute;width:0;height:0;border:0;visibility:hidden;pointer-events:none;';
            iframe.addEventListener('load', () => {
                if (signal?.aborted || !isCurrent()) {
                    finish(null);
                    return;
                }
                try {
                    const doc = iframe.contentDocument;
                    const body = doc?.body;
                    const root = doc?.documentElement;
                    const bodyStyle = iframe.contentWindow?.getComputedStyle?.(body);
                    const rootStyle = iframe.contentWindow?.getComputedStyle?.(root);
                    const writingMode = (
                        normalizedComputedWritingMode(bodyStyle)
                        || normalizedComputedWritingMode(rootStyle)
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
    }));
};

function makeReplaceURL(sourceURL, loadText = null, { isCurrent = () => true } = {}) {
    const rawSectionWritingDirectionCache = createOwnedAsyncCache();
    let destroyed = false;
    const isActive = () => !destroyed && isCurrent();
    const replaceURL = async (href, mediaType) => {
        if (!isActive()) return null;
        if (mediaType !== 'application/xhtml+xml' && mediaType !== 'text/html') {
            return null;
        }
        if (!href) {
            throw new Error('Direct processed section URL requires a spine href');
        }
        const writingDirection =
            await computeRawSectionWritingDirection(
                sourceURL,
                href,
                loadText,
                rawSectionWritingDirectionCache,
                isActive
            )
            ?? null;
        if (!isActive()) return null;
        const directURL = processedSectionURLForHref(sourceURL, href, writingDirection);
        if (!directURL || !isActive()) return null;
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
    replaceURL.destroy = () => {
        if (destroyed) return false;
        destroyed = true;
        rawSectionWritingDirectionCache.clear();
        return true;
    };
    return replaceURL;
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
    const activeContents = activeRendererContentsForLookup(renderer);
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
            documentStartedAtMs: readerDocumentStartedAtMs(),
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
                documentStartedAtMs: readerDocumentStartedAtMs(),
            });
        } catch (_error) {}
    }
};

const classifySingleMediaDocumentForInitialLayout = (doc, _reason = 'unknown') => {
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

const ignoreNextIncomingHideNavigation = (_source) => {
    globalThis.__manabiIgnoreNextIncomingHideNavigationCount = 1;
};

const ignoreNextIncomingRevealNavigation = (_source) => {
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

const recordPageTurnNavigationIntent = (direction, _source, _details = {}) => {
    const now = Date.now();
    if (direction === 'forward') {
        globalThis.__manabiLastForwardPageTurnHideAtMs = now;
    } else if (direction === 'backward') {
        globalThis.__manabiLastBackwardPageTurnRevealAtMs = now;
    }
};

const requestLookupCloseForPageMotion = (reason, _details = {}) => {
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

const runWithNavigationIntent = async (intent, operation, { timeoutMs = null } = {}) => {
    const navigationIntent = beginNavigationIntent(intent);
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
        navigationIntent.release();
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
    applyReaderPresentationStateToDocument(document, normalized, reason);
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
    } catch {
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
    const normalized = !!shouldHide;
    const body = document.body;
    if (body?.classList?.contains?.('nav-hidden')) {
        body.classList.remove('nav-hidden');
    }
    globalThis.reader?.navHUD?.setHideNavigationDueToScroll?.(normalized, source, {
        bridgeSource: source,
        bodyClassApplied: false,
    });
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

    globalThis.__swiftUIWebViewObscuredInsets = nextState;
    if (
        parseChromeInsetPixelValue(nextState.obscuredTopInset) > 0 ||
        parseChromeInsetPixelValue(nextState.toolbarBottomOffset) > 0 ||
        parseChromeInsetPixelValue(nextState.obscuredBottomInset) > 0
    ) {
        globalThis.__manabiLastPositiveChromeInsets = nextState;
    }
    applyResolvedChromeInsetState(nextState);
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
    const sentenceID = metadata?.sentenceID || null;
    const sidecarSentence = sentenceID
        ? resolvedBootstrap.sentenceArchive?.get?.(sentenceID)
        : null;
    return {
        sentenceHTML: sidecarSentence?.sentenceHTML ?? null,
        sentenceJMDictIDs: sidecarSentence?.sentenceJMDictIDs ?? null,
        vocabularyCandidateGroups:
            sidecarSentence?.vocabularyCandidateGroups ?? null,
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
                    const didIntersect = visibleRange.intersectsNode(segmentNode);
                    rangeCheckElapsedMs += performance.now() - rangeStartedAt;
                    return didIntersect;
                } catch (_error) {
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
            } catch {
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

const normalizedComputedWritingMode = (style) => {
    const candidates = [
        style?.writingMode,
        style?.webkitWritingMode,
        style?.getPropertyValue?.('writing-mode'),
        style?.getPropertyValue?.('-webkit-writing-mode'),
    ];
    return candidates
        .map(value => String(value ?? '').trim().toLowerCase())
        .find(value => value.length > 0)
        ?? null;
};

const normalizedComputedDirection = (style) => {
    const candidates = [
        style?.direction,
        style?.getPropertyValue?.('direction'),
    ];
    return candidates
        .map(value => String(value ?? '').trim().toLowerCase())
        .find(value => value.length > 0)
        ?? null;
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
            // EPUB sections can express writing mode through their author CSS
            // without carrying Foliate's post-layout marker classes. Read the
            // mounted document's computed cascade here, at the same boundary
            // used by paginator direction resolution, instead of treating the
            // absence of a marker as horizontal.
            const targetStyle = view.getComputedStyle?.(target) ?? null;
            const bodyStyle = body ? view.getComputedStyle?.(body) : targetStyle;
            const rootStyle = root ? view.getComputedStyle?.(root) : targetStyle;
            const computedStyles = [targetStyle, bodyStyle, rootStyle];
            const computedStyleValues = computedStyles.map(style => ({
                style,
                writingMode: normalizedComputedWritingMode(style),
                direction: normalizedComputedDirection(style),
            }));
            const computedVerticalStyle = computedStyleValues.find(({ writingMode }) =>
                writingMode?.startsWith('vertical') === true
            );
            const computedHorizontalStyle = computedStyleValues.find(({ writingMode }) =>
                writingMode === 'horizontal-tb'
            );
            const isVerticalWriting = body?.classList?.contains?.('reader-vertical-writing') === true
                || bodyDirection === 'vertical'
                || root?.classList?.contains?.('vrtl') === true
                || computedVerticalStyle != null;
            const isHorizontalWriting = bodyDirection === 'horizontal'
                || (!isVerticalWriting && root?.classList?.contains?.('hltr') === true)
                || (!isVerticalWriting && computedHorizontalStyle != null);
            const resolvedWritingMode = isVerticalWriting
                ? (computedVerticalStyle?.writingMode || 'vertical-rl')
                : (isHorizontalWriting ? 'horizontal-tb' : null);
            return {
                targetWritingMode: normalizedComputedWritingMode(targetStyle) ?? resolvedWritingMode,
                targetDirection: normalizedComputedDirection(targetStyle),
                bodyWritingMode: normalizedComputedWritingMode(bodyStyle) ?? resolvedWritingMode,
                bodyDirection: normalizedComputedDirection(bodyStyle),
                rootWritingMode: normalizedComputedWritingMode(rootStyle) ?? resolvedWritingMode,
                rootDirection: normalizedComputedDirection(rootStyle),
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
            targetWritingMode: normalizedComputedWritingMode(targetStyle),
            targetDirection: normalizedComputedDirection(targetStyle),
            bodyWritingMode: normalizedComputedWritingMode(bodyStyle),
            bodyDirection: normalizedComputedDirection(bodyStyle),
            rootWritingMode: normalizedComputedWritingMode(rootStyle),
            rootDirection: normalizedComputedDirection(rootStyle),
            isVerticalWriting: (
                body?.classList?.contains?.('reader-vertical-writing') === true
                || body?.dataset?.mnbFoliateWritingDirection === 'vertical'
                || root?.classList?.contains?.('vrtl') === true
                || normalizedComputedWritingMode(targetStyle)?.startsWith('vertical') === true
                || normalizedComputedWritingMode(bodyStyle)?.startsWith('vertical') === true
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
    const publicationIdentity = ebookDocumentFrameIdentity(doc);
    if (!publicationIdentity) return 0;
    const nativeLookupFrameKey = publicationIdentity.frameKey;
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
    const nativeLookupTargetsHandler = messageHandlers?.nativeLookupHitTargetsUpdated ?? null;
    if (typeof builder !== 'function') {
        // A committed document can legitimately have no lookup builder (for
        // example while a child frame is being replaced). The native side still
        // needs an authoritative empty set so targets from the previous frame
        // cannot survive under the new frame identity.
        if (typeof nativeLookupTargetsHandler?.postMessage === 'function') {
            nativeLookupTargetsHandler.postMessage({
                targets: [],
                reason,
                nativeLookupFrameKey,
                nativeLookupDocumentURL: publicationIdentity.documentURL,
                isExplicitReset: false,
                isAuthoritativeTargetSet: true,
                visualViewportScale,
                viewportWidth,
                viewportHeight,
                viewportLeft,
                viewportTop,
            });
        }
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
    if (typeof nativeLookupTargetsHandler?.postMessage !== 'function') {
        manabiTimelineMeasure('nativeLookup.targets.post', startedAt, {
            reason,
            builder: true,
            messageHandler: false,
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
    nativeLookupTargetsHandler.postMessage({
        targets: messageTargets,
        reason,
        nativeLookupFrameKey,
        nativeLookupDocumentURL: publicationIdentity.documentURL,
        isExplicitReset: false,
        isAuthoritativeTargetSet: true,
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

const postNativeLookupPageTurnAttemptStarted = (
    reason = 'unspecified',
    navigationToken = null
) => {
    const normalizedNavigationToken = typeof navigationToken === 'string' && navigationToken.length > 0
        ? navigationToken
        : null;
    manabiTimelineMark('nativeLookup.pageTurnAttemptStarted', {
        reason,
        navigationToken: normalizedNavigationToken,
        force: true,
    });
    window.webkit?.messageHandlers?.nativeLookupHitTargetsUpdated?.postMessage?.({
        targets: [],
        reason: 'nativeLookup.pageTurnAttemptStarted',
        sourceReason: reason,
        lookupNavigationToken: normalizedNavigationToken,
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
    } catch {
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

const buildVisiblePageTrackingStates = (doc, articleReadingProgress, visibleRange = null, visibleSegmentsResult = null) => {
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

const fetchNativeEntries = async (sourceURL) => {
    const response = await fetch(`ebook://ebook/entries?${makeNativeSourceURLQuery(sourceURL)}`, {
        headers: {
            'X-Ebook-Source-URL': sourceURL,
        },
    })
    if (!response.ok) {
        throw new Error(`Failed to load native EPUB entries: ${response.status}`)
    }
    return await response.json()
}

const fetchNativeEntryResponse = async (sourceURL, subpath, signal = null) => {
    const response = await fetch(`ebook://ebook/entry?subpath=${encodeURIComponent(subpath)}&${makeNativeSourceURLQuery(sourceURL)}`, {
        headers: {
            'X-Ebook-Source-URL': sourceURL,
        },
        signal: signal ?? undefined,
    })
    if (!response.ok) {
        return null
    }
    return response
}

const readNativeEntryText = async (response) => {
    if (!response) return null
    const arrayBuffer = await response.arrayBuffer()
    const charset = response.headers?.get?.('content-type')?.match(/charset=([^;]+)/i)?.[1]?.trim() || 'utf-8'
    let decoder
    try {
        decoder = new TextDecoder(charset)
    } catch (_error) {
        decoder = new TextDecoder('utf-8')
    }
    return decoder.decode(arrayBuffer)
}

const readNativeEntryBlob = async (response) => {
    if (!response) return null
    const arrayBuffer = await response.arrayBuffer()
    const mimeType = response.headers?.get?.('content-type') || ''
    return new Blob([arrayBuffer], mimeType ? { type: mimeType } : undefined)
}

const makeNativeEpubLoader = async (url, { isCurrent = () => true } = {}) => {
    if (!isCurrent()) throw readerOpenSupersededError()
    const { entries: rawEntries = [] } = await fetchNativeEntries(url)
    if (!isCurrent()) throw readerOpenSupersededError()
    const entries = rawEntries.map(function(entry) {
        return {
            filename: entry.path,
            uncompressedSize: entry.size ?? 0,
        };
    })
    const sizeMap = new Map(entries.map(function(entry) { return [entry.filename, entry.uncompressedSize]; }))
    const entryNames = new Set(entries.map(function(entry) { return entry.filename; }))
    let destroyed = false
    const isActive = () => !destroyed && isCurrent()
    const replaceText = makeReplaceText({
        allowForegroundHTML: false,
        isCurrent: isActive,
    })
    const loadText = async (name, { signal = null } = {}) => {
        if (signal?.aborted || !isActive() || !entryNames.has(name)) {
            return null
        }
        const response = await fetchNativeEntryResponse(url, name, signal)
        if (!isActive()) return null
        const text = await readNativeEntryText(response)
        return isActive() ? text : null
    }
    const replaceURL = makeReplaceURL(url, loadText, { isCurrent: isActive })
    return {
        entries,
        loadText,
        loadBlob: async (name) => {
            if (!isActive() || !entryNames.has(name)) {
                return null
            }
            const response = await fetchNativeEntryResponse(url, name)
            if (!isActive()) return null
            const blob = await readNativeEntryBlob(response)
            return isActive() ? blob : null
        },
        getSize: name => isActive() ? (sizeMap.get(name) ?? 0) : 0,
        replaceText,
        replaceURL,
        sourceURL: url,
        destroy: () => {
            if (destroyed) return false
            destroyed = true
            replaceText.destroy?.()
            replaceURL.destroy?.()
            entryNames.clear()
            sizeMap.clear()
            entries.length = 0
            return true
        },
    }
}

const closeZipReader = reader => {
    try {
        const result = reader?.close?.()
        Promise.resolve(result).catch(() => {})
    } catch (_error) {}
}

const makeZipLoader = async (file, { isCurrent = () => true } = {}) => {
    if (!isCurrent()) throw readerOpenSupersededError()
    const {
        configure,
        ZipReader,
        BlobReader,
        TextWriter,
        BlobWriter
    } =
    await import('./vendor/zip.js')
    if (!isCurrent()) throw readerOpenSupersededError()
    configure({
        useWebWorkers: false
    })
    const reader = new ZipReader(new BlobReader(file))
    let entries
    try {
        entries = await reader.getEntries()
        if (!isCurrent()) throw readerOpenSupersededError()
    } catch (error) {
        closeZipReader(reader)
        throw error
    }
    const map = new Map(entries.map(function(entry) { return [entry.filename, entry]; }))
    let destroyed = false
    const isActive = () => !destroyed && isCurrent()
    const load = f => async (name, ...args) => {
        if (!isActive() || !map.has(name)) return null
        const value = await f(map.get(name), ...args)
        return isActive() ? value : null
    }
    const loadText = load(function(entry) { return entry.getData(new TextWriter()); })
    const loadBlob = load(function(entry, type) { return entry.getData(new BlobWriter(type)); })
    const getSize = name => isActive() ? (map.get(name)?.uncompressedSize ?? 0) : 0
    const replaceText = makeReplaceText({ isCurrent: isActive })
    return {
        entries,
        loadText,
        loadBlob,
        getSize,
        replaceText,
        destroy: () => {
            if (destroyed) return false
            destroyed = true
            replaceText.destroy?.()
            map.clear()
            entries.length = 0
            closeZipReader(reader)
            return true
        },
    }
}

const isCBZ = ({
    name,
    type
}) =>
type === 'application/vnd.comicbook+zip' || name.endsWith('.cbz')

const isFBZ = ({
    name,
    type
}) =>
type === 'application/x-zip-compressed-fb2' ||
name.endsWith('.fb2.zip') || name.endsWith('.fbz')

const readerOpenSupersededError = () => {
    const error = new Error('Reader open was superseded')
    error.code = 'reader-open-superseded'
    return error
}

const destroyReaderBook = book => {
    try {
        book?.destroy?.()
    } catch (_error) {}
}

const destroyReaderSource = source => {
    try {
        const result = source?.destroy?.()
        Promise.resolve(result).catch(() => {})
    } catch (_error) {}
}

const initializeEPUBBook = async (EPUB, loader) => {
    const book = new EPUB(loader)
    try {
        return await book.init()
    } catch (error) {
        destroyReaderBook(book)
        throw error
    }
}

const getView = async (source, {
    isCurrent = () => true,
    onViewCreated = null,
} = {}) => {
    let book
    if (source?.kind === 'native' && source.url) {
        const {
            EPUB
        } = await import('./epub.js')
        const loader = await makeNativeEpubLoader(source.url, { isCurrent })
        book = await initializeEPUBBook(EPUB, loader)
    } else if (source?.kind === 'file' && source.file?.size) {
        const file = source.file
        if (await isZip(file)) {
            const loader = await makeZipLoader(file, { isCurrent })
            try {
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
                    book = await initializeEPUBBook(EPUB, loader)
                }
            } catch (error) {
                destroyReaderSource(loader)
                throw error
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
    if (!isCurrent()) {
        destroyReaderBook(book)
        throw readerOpenSupersededError()
    }
    const view = document.createElement('foliate-view')
    onViewCreated?.(view)
    if (!isCurrent()) {
        destroyReaderBook(book)
        view.close?.()
        throw readerOpenSupersededError()
    }
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
    try {
        const opened = await view.open(book)
        if (opened !== true || !isCurrent()) {
            throw readerOpenSupersededError()
        }
    } catch (error) {
        view.close?.()
        view.remove?.()
        throw error
    }

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
        view.registerCleanup?.(() => {
            window.removeEventListener('resize', syncSideNavWidth);
        });
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
    #closed = false;
    #lifecycleGeneration = 0;
    #initialDisplayGeneration = 0;
    #didDisplaySequence = 0;
    #listenerCleanups = new Set();
    #globalBindingCleanups = new Set();
    #documentScopes = new Map();
    #documentScopeSequence = 0;
    #lastPublishedCurrentContentPageKey = null;
    #postInitialOpenWorkHandle = null;
    #sidebarCloseHandle = null;
    #navButtonOperations = new Set();
    #completionActionSequence = 0;
    get isClosed() {
        return this.#closed;
    }
    #isLifecycleCurrent(generation) {
        return !this.#closed && this.#lifecycleGeneration === generation;
    }
    #isRendererLifecycleCurrent(generation, renderer) {
        return this.#isLifecycleCurrent(generation)
            && this.view?.renderer === renderer;
    }
    #invalidateCompletionAction() {
        this.#completionActionSequence += 1;
        this.completionActionBusy = false;
    }
    #listen(target, type, listener, options) {
        if (!target?.addEventListener || typeof listener !== 'function') {
            return () => {};
        }
        target.addEventListener(type, listener, options);
        let active = true;
        const cleanup = () => {
            if (!active) return;
            active = false;
            this.#listenerCleanups.delete(cleanup);
            target.removeEventListener?.(type, listener, options);
        };
        this.#listenerCleanups.add(cleanup);
        return cleanup;
    }
    #beginDocumentScope({ doc, location = null, index = null } = {}) {
        if (!isDocumentLike(doc)) return null;
        this.#releaseDocumentScope(doc, 'document-reloaded');
        const scope = {
            id: ++this.#documentScopeSequence,
            doc,
            location: location ?? doc.location?.href ?? null,
            index: Number.isInteger(index) ? index : null,
            lifecycleGeneration: this.#lifecycleGeneration,
            committed: false,
            cleanups: new Set(),
            animationFrames: new Set(),
        };
        this.#documentScopes.set(doc, scope);
        return scope;
    }
    #isDocumentScopeCurrent(scope, {
        requireCommitted = false,
        requirePrimary = false,
    } = {}) {
        if (!scope || !this.#isLifecycleCurrent(scope.lifecycleGeneration)) return false;
        if (this.#documentScopes.get(scope.doc) !== scope) return false;
        if (requireCommitted && scope.committed !== true) return false;
        if (requirePrimary) {
            const primaryDoc = getPrimaryRendererContent(this.view?.renderer)?.doc ?? null;
            if (primaryDoc !== scope.doc) return false;
        }
        return true;
    }
    #listenInDocumentScope(scope, target, type, listener, options) {
        if (!scope || !target?.addEventListener || typeof listener !== 'function') {
            return () => {};
        }
        target.addEventListener(type, listener, options);
        let active = true;
        const cleanup = () => {
            if (!active) return;
            active = false;
            scope.cleanups.delete(cleanup);
            target.removeEventListener?.(type, listener, options);
        };
        scope.cleanups.add(cleanup);
        return cleanup;
    }
    #scheduleDocumentScopeFrame(scope, callback, options = {}) {
        if (!scope || typeof callback !== 'function') return null;
        const handle = requestAnimationFrame(() => {
            scope.animationFrames.delete(handle);
            if (!this.#isDocumentScopeCurrent(scope, options)) return;
            callback();
        });
        scope.animationFrames.add(handle);
        return handle;
    }
    #releaseDocumentScope(doc, _reason = 'document-unload') {
        const scope = doc ? this.#documentScopes.get(doc) : null;
        if (!scope) return false;
        this.#documentScopes.delete(doc);
        for (const handle of scope.animationFrames) cancelAnimationFrame(handle);
        scope.animationFrames.clear();
        for (const cleanup of [...scope.cleanups]) {
            try {
                cleanup();
            } catch (_error) {}
        }
        scope.cleanups.clear();
        if (doc.__manabiMay20BlankTapLoggingOwner === scope) {
            try {
                delete doc.__manabiMay20BlankTapLoggingOwner;
            } catch (_error) {
                doc.__manabiMay20BlankTapLoggingOwner = null;
            }
        }
        return true;
    }
    #releaseAllDocumentScopes(reason = 'reader-close') {
        for (const doc of [...this.#documentScopes.keys()]) {
            this.#releaseDocumentScope(doc, reason);
        }
    }
    #publishCurrentContentPage(reason = 'unspecified', explicitDoc = null) {
        if (this.#closed) return false;
        const doc = explicitDoc ?? getPrimaryRendererContent(this.view?.renderer)?.doc ?? null;
        if (!isDocumentLike(doc)) return false;
        const currentPageURL = doc.location?.href ?? null;
        if (!currentPageURL) return false;
        const key = `${window.top.location.href}\n${currentPageURL}`;
        if (this.#lastPublishedCurrentContentPageKey === key) return false;
        this.#lastPublishedCurrentContentPageKey = key;
        window.webkit?.messageHandlers?.updateCurrentContentPage?.postMessage?.({
            topWindowURL: window.top.location.href,
            currentPageURL,
            reason,
        });
        return true;
    }
    #refreshCommittedDocumentAfterFonts(scope, reason) {
        if (!this.#isDocumentScopeCurrent(scope, {
            requireCommitted: true,
            requirePrimary: true,
        })) return false;
        if (isCacheWarmerDocument(scope.doc) || scope.doc.fonts?.status !== 'loaded') {
            return false;
        }
        this.#invalidateVisiblePageSegmentSnapshot(reason);
        this.#scheduleNativeLookupHitTargetRefreshSettle(reason, scope.doc);
        return true;
    }
    #commitDocumentScope(scope, reason = 'document-committed') {
        if (!this.#isDocumentScopeCurrent(scope)) return false;
        scope.committed = true;
        if (!this.#isDocumentScopeCurrent(scope, { requirePrimary: true })) return true;
        this.#publishCurrentContentPage(reason, scope.doc);
        const sourceHref = scope.doc?.body?.dataset?.mnbSourceHref || null;
        if (!isCacheWarmerDocument(scope.doc)) {
            this.#scheduleDocumentScopeFrame(scope, () => {
                window.manabi_recordLiveSettledSection?.(sourceHref);
            }, { requireCommitted: true, requirePrimary: true });
        }
        this.#refreshCommittedDocumentAfterFonts(scope, `${reason}.fonts-ready`);
        if (MANABI_ENABLE_EBOOK_PAGE_TRACKING_BUTTONS) {
            this.#schedulePageTrackingSync(reason, scope.doc, 2);
        }
        return true;
    }
    #currentPageTrackingDocument(explicitDoc = null) {
        const doc = getCurrentRendererDocument(this.view?.renderer, explicitDoc);
        if (!isDocumentLike(doc)) return null;
        const scope = this.#documentScopes.get(doc);
        if (scope && !this.#isDocumentScopeCurrent(scope, {
            requireCommitted: true,
            requirePrimary: true,
        })) {
            return null;
        }
        return doc;
    }
    #bindGlobal(target, key, value) {
        if (!target || typeof key !== 'string') return () => {};
        target[key] = value;
        let active = true;
        const cleanup = () => {
            if (!active) return;
            active = false;
            this.#globalBindingCleanups.delete(cleanup);
            if (target[key] === value) {
                try {
                    delete target[key];
                } catch (_error) {
                    target[key] = undefined;
                }
            }
        };
        this.#globalBindingCleanups.add(cleanup);
        return cleanup;
    }
    #removeOwnedListenersAndBindings() {
        for (const cleanup of [...this.#listenerCleanups]) {
            try {
                cleanup();
            } catch (_error) {}
        }
        for (const cleanup of [...this.#globalBindingCleanups]) {
            try {
                cleanup();
            } catch (_error) {}
        }
    }
    #finishNavButtonOperations() {
        for (const operation of [...this.#navButtonOperations]) {
            operation.finish?.();
        }
    }
    #readerClosedPageTurnResult(phase = 'reader-closed') {
        return {
            ignored: true,
            reason: 'readerClosed',
            failureReason: 'readerClosed',
            readerLifecyclePhase: phase,
            moved: false,
            movementNotOwned: true,
            movementDisposition: PAGE_TURN_MOVEMENT_DISPOSITION.notOwned,
        };
    }
    close(reason = 'unspecified') {
        if (this.#closed) return false;
        this.#closed = true;
        this.#lifecycleGeneration += 1;
        this.#relocateSequence += 1;
        this.visiblePageCollectionGeneration += 1;
        this.nativeLookupHitTargetRefreshGeneration += 1;

        const restoreOwner = lastPositionRestoreCoordinator.current;
        if (restoreOwner?.context?.reader === this) {
            lastPositionRestoreCoordinator.cancel(
                restoreOwner,
                `reader-closed:${reason}`
            );
            resetRestoreTransactionGlobals();
        }

        this.scheduleGoToPageNumber?.cancel?.();
        this.scheduleGoToFraction?.cancel?.();
        this.#postUpdateReadingProgressMessage?.cancel?.();
        clearTimeout(this.loadingVisualTimer);
        this.loadingVisualTimer = null;
        clearTimeout(this.#postInitialOpenWorkHandle);
        this.#postInitialOpenWorkHandle = null;
        clearTimeout(this.#sidebarCloseHandle);
        this.#sidebarCloseHandle = null;

        const cancelFrameField = (field) => {
            if (this[field] == null) return;
            cancelAnimationFrame(this[field]);
            this[field] = null;
        };
        for (const field of [
            'pageTrackingRetryHandle',
            'pageTrackingDeferredHandle',
            'pageTrackingDeferredFrameHandle',
            'nativeMarkReadStateRefreshHandle',
            'initialPaginatorSettleHandle',
            'nativeLookupHitTargetRefreshHandle',
        ]) {
            cancelFrameField(field);
        }
        clearTimeout(this.nativeLookupHitTargetRefreshFallbackHandle);
        this.nativeLookupHitTargetRefreshFallbackHandle = null;
        this.pageTrackingDeferredReadyCleanup?.();
        this.pageTrackingDeferredReadyCleanup = null;
        for (const key of ['l', 'r']) {
            if (this.#chevronFadeAnimationFrames[key] != null) {
                cancelAnimationFrame(this.#chevronFadeAnimationFrames[key]);
                this.#chevronFadeAnimationFrames[key] = null;
            }
            this.#chevronFadeAnimationCleanup[key]?.();
            this.#chevronFadeAnimationCleanup[key] = null;
            this.#releaseSideNavChevronHoverSuppression(key);
        }

        const queuedPageTurnRun = this.#queuedPageTurnRun;
        this.#queuedPageTurnRun = null;
        queuedPageTurnRun?.resolve?.(
            this.#readerClosedPageTurnResult('queued-page-turn')
        );
        this.#pageTurnInFlight = false;

        this.#resolveInitialDisplaySettled(`reader-closed:${reason}`);
        this.#resolveDisplaySettledWaiters(`reader-closed:${reason}`);
        this.#finishNavButtonOperations();
        this.navHUD?.destroy?.();
        this.#releaseAllDocumentScopes(`reader-closed:${reason}`);
        this.#lastPublishedCurrentContentPageKey = null;
        this.#removeOwnedListenersAndBindings();
        resetReaderTransientState(globalThis, {
            owner: this,
            currentOwner: globalThis.reader,
        });

        this.#tocView?.element?.remove?.();
        this.#tocView = null;
        this.#bookForSidebarCover = null;
        this.#sidebarCoverLoadPromise = null;
        if (this.#sidebarCoverObjectURL) {
            URL.revokeObjectURL(this.#sidebarCoverObjectURL);
            this.#sidebarCoverObjectURL = null;
        }

        const view = this.view;
        this.view = null;
        view?.close?.();
        view?.remove?.();
        return true;
    }
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
    setLoadingIndicator(visible, reason = 'unspecified', {
        paintCommitted = false,
        terminal = false,
    } = {}) {
        if (this.#closed) return;
        const body = document.body;
        if (!body) return;
        const loadingIndicator = document.getElementById('loading-indicator');
        const previousVisible = body.classList.contains('loading');
        const nextVisible = !!visible;
        if (nextVisible) {
            if (!previousVisible) {
                this.hasReachedLoadingDidDisplayBoundary = false;
            }
            this.loadingPaintPending = true;
        } else if (this.loadingPaintPending) {
            // Successful navigation waits for didDisplay; a terminal restore has
            // no later paint event guaranteed to release this input-blocking cover.
            if (!paintCommitted && !terminal) {
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
    finishRestoreLoading(settleResult, reason) {
        const hasVisibleContent = settleResult?.settled === true;
        this.setLoadingIndicator(
            false,
            `${reason}.${hasVisibleContent ? 'visibleContent' : 'terminal'}`,
            { terminal: !hasVisibleContent }
        );
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
    #chevronHoverSuppressionCleanup = {
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
    #relocateSequence = 0;
    #explicitRelocationSequence = 0;
    initialDisplaySettled = false;
    hasReachedLoadingDidDisplayBoundary = false;
    initialDisplaySettledPromise = null;
    initialDisplaySettledResolve = null;
    displaySettledSequence = 0;
    displaySettledWaiters = [];
    hasCompletedLastPositionLoadAttempt = false
    hasLoadedLastPosition = false
    markedAsFinished = false;
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
    lastPageTrackingStateSignature = null;
    lastPageTrackingStateSnapshot = null;
    lastRenderedPageTrackingSignature = null;
    pageTrackingStatesGeneration = -1;
    pageTrackingRetryHandle = null;
    pageTrackingDeferredHandle = null;
    pageTrackingDeferredFrameHandle = null;
    pageTrackingDeferredReadyCleanup = null;
    nativeMarkReadStateRefreshHandle = null;
    initialPaginatorSettleHandle = null;
    hasSettledInitialPaginatorLayout = false;
    sameIndexGoToDidDisplaySkips = 0;
    lastCFIPersistenceObservation = null;
    unstableCFIs = new Set();
    visiblePageCollectionGeneration = 0;
    visiblePageSegmentSnapshot = null;
    lastInvalidatedVisiblePageSegmentSnapshot = null;
    nativeLookupHitTargetRefreshHandle = null;
    nativeLookupHitTargetRefreshFallbackHandle = null;
    nativeLookupHitTargetRefreshGeneration = 0;
    pendingNativeLookupHitTargetRefresh = null;
    pendingBookContentHideNavigationDueToScroll = null;
    annotations = new Map()
    annotationsByValue = new Map()
    openSideBar() {
        if (this.#closed) return false
        clearTimeout(this.#sidebarCloseHandle)
        this.#sidebarCloseHandle = null
        $('#dimming-overlay').removeAttribute('hidden')
        $('#side-bar').removeAttribute('hidden')
        $('#dimming-overlay').classList.add('show')
        $('#side-bar').classList.add('show')
        void this.#ensureSidebarCoverLoaded()
        if (this.#tocView?.setCurrentHref && this.view?.renderer?.tocItem?.href) {
            this.#tocView.setCurrentHref(this.view.renderer.tocItem.href)
        }
        return true
    }
    #ensureSidebarCoverLoaded() {
        if (this.#closed) return Promise.resolve()
        if (this.#sidebarCoverLoadPromise) return this.#sidebarCoverLoadPromise
        const coverElement = $('#side-bar-cover')
        if (!coverElement) return Promise.resolve()
        if (coverElement?.getAttribute?.('src')) return Promise.resolve()
        const book = this.#bookForSidebarCover
        if (typeof book?.getCover !== 'function') return Promise.resolve()
        const lifecycleGeneration = this.#lifecycleGeneration
        this.#sidebarCoverLoadPromise = Promise.resolve(book.getCover())
            .then(blob => {
                if (!blob || !this.#isLifecycleCurrent(lifecycleGeneration)) return
                if (this.#sidebarCoverObjectURL) {
                    URL.revokeObjectURL(this.#sidebarCoverObjectURL)
                }
                this.#sidebarCoverObjectURL = URL.createObjectURL(blob)
                coverElement.src = this.#sidebarCoverObjectURL
            })
            .catch(() => {})
        return this.#sidebarCoverLoadPromise
    }
    closeSideBar() {
        if (this.#closed) return false
        clearTimeout(this.#sidebarCloseHandle)
        const lifecycleGeneration = this.#lifecycleGeneration
        $('#dimming-overlay').classList.remove('show')
        $('#side-bar').classList.remove('show')
        this.#sidebarCloseHandle = setTimeout(() => {
            this.#sidebarCloseHandle = null
            if (!this.#isLifecycleCurrent(lifecycleGeneration)) return
            if (!$('#side-bar').classList.contains('show')) {
                $('#dimming-overlay').setAttribute('hidden', '')
                $('#side-bar').setAttribute('hidden', '')
            }
        }, 360)
        return true
    }
    toggleTableOfContents() {
        if ($('#side-bar').classList.contains('show')) {
            this.closeSideBar()
        } else {
            this.openSideBar()
        }
    }
    #nextExplicitRelocationID(source) {
        this.#explicitRelocationSequence += 1;
        return `reader-relocate-${this.#explicitRelocationSequence}-${source}`;
    }
    async #performExplicitRelocateNavigation(source, operation, isAccepted) {
        const relocationID = this.#nextExplicitRelocationID(source);
        const ownership = this.navHUD?.requestExplicitRelocateHistoryMutation?.(
            source,
            relocationID
        );
        try {
            const result = await operation(relocationID);
            const accepted = isAccepted(result);
            if (!accepted) {
                this.navHUD?.cancelExplicitRelocateHistoryMutation?.(ownership);
            }
            return accepted;
        } catch (error) {
            this.navHUD?.cancelExplicitRelocateHistoryMutation?.(ownership);
            throw error;
        }
    }
    async _goToDescriptor(descriptor, navigationOptions = {}) {
        if (!descriptor || !this.view) return false;
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
            try {
                const result = await runWithNavigationIntent({
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
                }, navigationOptions));
                return rendererNavigationAccepted(result);
            } catch (error) {
                console.error(error);
                return false;
            }
        }
        if (typeof descriptor.cfi === 'string' && descriptor.cfi) {
            try {
                const result = await runWithNavigationIntent({
                    source: 'goToDescriptor',
                    target: 'view.goTo',
                    cfiLength: descriptor.cfi.length,
                    pageItemKey: descriptor.pageItemKey ?? null,
                }, () => this.view.goTo(descriptor.cfi, navigationOptions));
                return result != null;
            } catch (error) {
                console.error(error);
                return false;
            }
        }
        if (typeof descriptor.fraction === 'number' && Number.isFinite(descriptor.fraction)) {
            return await runWithNavigationIntent({
                source: 'goToDescriptor',
                target: 'view.goToFraction',
                fraction: descriptor.fraction,
                pageItemKey: descriptor.pageItemKey ?? null,
            }, () => this.view.goToFraction(descriptor.fraction, navigationOptions));
        }
        return false;
    }
    async goToHref(href, source = 'unknown') {
        if (!this.view || typeof href !== 'string' || !href) {
            return false;
        }
        return await this.#performExplicitRelocateNavigation(
            'goToHref',
            (relocationID) => runWithNavigationIntent({
                source: 'goToHref',
                target: 'view.goTo',
                href,
                requestSource: source,
            }, () => this.view.goTo(href, { relocationID })),
            result => result != null
        );
    }
    async goToPercent(percent, source = 'unknown') {
        if (!this.view) {
            return false;
        }
        const numericPercent = Number(percent);
        const clampedPercent = Math.max(0, Math.min(100, numericPercent));
        if (!Number.isFinite(clampedPercent)) {
            return false;
        }
        const fraction = clampedPercent / 100;
        return await this.#performExplicitRelocateNavigation(
            'goToPercent',
            (relocationID) => runWithNavigationIntent({
                source: 'goToPercent',
                target: 'view.goToFraction',
                percent: clampedPercent,
                fraction,
                requestSource: source,
            }, () => this.view.goToFraction(fraction, { relocationID })),
            result => result === true
        );
    }
    async goToLocationNumber(locationNumber, source = 'unknown') {
        if (!this.view) {
            return false;
        }
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
        return await this.#performExplicitRelocateNavigation(
            'goToLocation',
            (relocationID) => runWithNavigationIntent({
                source: 'goToLocationNumber',
                target: 'view.goToFraction',
                locationNumber: clampedLocationNumber,
                locationTotal: maxLocationNumber,
                fraction,
                requestSource: source,
            }, () => this.view.goToFraction(fraction, { relocationID })),
            result => result === true
        );
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
        for (const content of contents) {
            const body = content?.doc?.body;
            if (!body) continue;
            const isPageTurnNavigationState = reason.includes('relocate.page-turn')
                || reason.includes('navHUD.visibilityChange.relocate.page-turn');
            applyNavigationHiddenVisualStateToEbookBody(body, hidden, {
                reason,
                refreshPaint: !isPageTurnNavigationState,
            });
        }
    }
    constructor() {
        applyStoredChromeInsets('reader.constructor');
        this.navHUD = new NavigationHUD({
            formatPercent: value => percentFormat.format(value),
            getRenderer: () => this.view?.renderer,
            onJumpRequest: (descriptor, options) => this._goToDescriptor(descriptor, options),
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
                .catch((error) => {
                    console.error(error);
                });
        }, 250);
        this.#listen(document.getElementById('nav-primary-text'), 'click', (event) => {
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
        this.#listen(document.getElementById('nav-hidden-primary-text'), 'click', (event) => {
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
        this.#listen(document.getElementById('nav-title-location-label'), 'click', (event) => {
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
        this.#listen(document.getElementById('nav-bar'), 'click', (event) => {
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
        this.#listen($('#side-bar-close-button'), 'click', () => {
            this.closeSideBar()
        })
        this.#listen($('#dimming-overlay'), 'click', () => this.closeSideBar())
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
            return isEventInsideElementCircle(event, circle);
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
        this.#listen(pageTrackingButtons, 'touchstart', (event) => {
            if (absorbPageTrackingButtonEvent(event)) {
                return;
            }
            revealNavigationFromPageTracking(event, 'page-tracking-buttons.touchstart.reveal');
        }, { capture: true, passive: false });
        this.#listen(pageTrackingButtons, 'pointerdown', (event) => {
            if (absorbPageTrackingButtonEvent(event)) {
                return;
            }
            revealNavigationFromPageTracking(event, 'page-tracking-buttons.pointerdown.reveal');
        }, { capture: true });
        this.#listen(pageTrackingButtons, 'click', (event) => {
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
        this.#bindGlobal(window, 'manabi_markVisiblePageAsRead', async (source = 'native') => {
            return await this.markVisiblePageAsRead(source);
        });
        this.#listen(window, 'resize', () => {
            this.#invalidateVisiblePageSegmentSnapshot();
        });
        this.#listen(window.visualViewport, 'resize', () => {
            this.#invalidateVisiblePageSegmentSnapshot();
        });
        this.#bindGlobal(window, 'manabiInvalidateVisiblePageSegmentSnapshot', (reason = 'manual') => {
            this.#invalidateVisiblePageSegmentSnapshot(reason);
        });
        this.#bindGlobal(window, 'manabiRefreshVisibleTrackingStatuses', (reason = 'manual') => {
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
        });
        this.#listen(screen.orientation, 'change', () => {
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
        clearTimeout(this.nativeLookupHitTargetRefreshFallbackHandle);
        this.nativeLookupHitTargetRefreshFallbackHandle = null;
        this.nativeLookupHitTargetRefreshGeneration += 1;
        if (!shouldResetNativeLookupTargets && this.hasCompletedLastPositionLoadAttempt === true) {
            this.#scheduleNativeLookupHitTargetRefreshSettle(`invalidation:${sourceReason}`);
        }
    }
    async #syncPageTrackingButtons(reason = 'unspecified', explicitDoc = null, retryCount = 0) {
        const syncStartedAt = performance.now();
        const isRestorePending =
            reason === 'document-load'
            && globalThis.reader
            && globalThis.reader.hasCompletedLastPositionLoadAttempt !== true;
        if (isRestorePending) {
            this.#queuePageTrackingRetry(reason, explicitDoc, retryCount);
            return;
        }
        const doc = this.#currentPageTrackingDocument(explicitDoc);
        if (isDocumentLike(explicitDoc) && !doc) {
            return;
        }
        if (!isDocumentLike(doc)) {
            if (retryCount > 0) {
                this.#queuePageTrackingRetry(reason, explicitDoc, retryCount);
                return;
            }
            this.pageTrackingStates = [];
            this.pageTrackingStatesGeneration = -1;
            this.#renderPageTrackingButtons(reason);
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
        if (
            syncGeneration !== this.visiblePageCollectionGeneration
            || this.#currentPageTrackingDocument(doc) !== doc
        ) {
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
            const builtState = buildVisiblePageTrackingStates(doc, this.articleReadingProgress, visibleRange, visibleSegmentsResult);
            states = builtState.states;
            diagnostics = builtState.diagnostics;
            buildStatesElapsedMs = performanceNowMs() - buildStatesStartedAt;
            if (
                syncGeneration !== this.visiblePageCollectionGeneration
                || this.#currentPageTrackingDocument(doc) !== doc
            ) {
                return;
            }
            this.lastPageTrackingStateSignature = pageTrackingSignature;
            this.lastPageTrackingStateSnapshot = { states, diagnostics };
        }
        if (
            syncGeneration !== this.visiblePageCollectionGeneration
            || this.#currentPageTrackingDocument(doc) !== doc
        ) {
            return;
        }
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
            this.#queuePageTrackingRetry(reason, null, retryCount);
            return;
        }
        this.pageTrackingStates = states;
        this.pageTrackingStatesGeneration = syncGeneration;
        const renderStartedAt = performanceNowMs();
        this.#renderPageTrackingButtons(reason);
        const renderElapsedMs = performanceNowMs() - renderStartedAt;
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
    }
    applyBookReadingProgress(articleReadingProgress, _reason = 'unspecified') {
        const incomingProgress = normalizeArticleReadingProgress(articleReadingProgress);
        const incomingReadSegmentIdentifiers = new Set(incomingProgress.readSegmentIdentifiers);
        const incomingSentenceIdentifiersRead = new Set(incomingProgress.sentenceIdentifiersRead);
        for (const segmentIdentifier of this.optimisticReadSegmentIdentifiers) {
            incomingReadSegmentIdentifiers.add(segmentIdentifier);
        }
        for (const sentenceIdentifier of this.optimisticSentenceIdentifiersRead) {
            incomingSentenceIdentifiersRead.add(sentenceIdentifier);
        }
        incomingProgress.readSegmentIdentifiers = Array.from(incomingReadSegmentIdentifiers);
        incomingProgress.sentenceIdentifiersRead = Array.from(incomingSentenceIdentifiersRead);
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
        // Finish waits for native progress to acknowledge the state change. A
        // restart owns renderer navigation until its own promise settles.
        if (this.completionAction?.type === 'finish') {
            this.#invalidateCompletionAction();
        }
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
        const lifecycleGeneration = this.#lifecycleGeneration;
        const renderer = this.view?.renderer ?? null;
        const completionActionSequence = ++this.#completionActionSequence;
        const isCurrentCompletionAction = () =>
            this.#isLifecycleCurrent(lifecycleGeneration)
            && this.#completionActionSequence === completionActionSequence;
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
                    await renderer?.firstSection?.();
                    break;
                default:
                    break;
            }
        } finally {
            if (actionType !== 'finish' && isCurrentCompletionAction()) {
                this.completionActionBusy = false;
                if (this.view?.renderer === renderer) {
                    this.#renderPageTrackingButtons('completion-action-finished');
                }
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
        const doc = getPrimaryRendererContent(this.view?.renderer)?.doc;
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
        const doc = getPrimaryRendererContent(this.view?.renderer)?.doc;
        if (!isDocumentLike(doc)) {
            return null;
        }
        const segmentNodes = Array.from(doc.querySelectorAll(manabiReaderSegmentSelector))
            .filter((segmentNode) => !segmentNode.closest('.tippy-box'));
        const segmentsByIdentifier = new Map();
        const sentenceIdentifiers = new Set();
        for (const segmentNode of segmentNodes) {
            const segmentIdentifier = segmentIdentifierForNode(segmentNode);
            if (typeof segmentIdentifier !== 'string' || segmentIdentifier.length === 0) {
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
        const advanceOwner = {
            lifecycleGeneration: this.#lifecycleGeneration,
            renderer: this.view?.renderer ?? null,
            visiblePageCollectionGeneration: this.visiblePageCollectionGeneration,
        };
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
        await this.#advanceAfterMarkRead(advanceOwner);
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
            ignoreNextIncomingHideNavigation('native-page-tracking-button');
        }
        await this.#markPageClusterAsRead(stateID);
        return true;
    }
    async #ensureVisiblePageTrackingState(reason = 'native-demand', explicitDoc = null) {
        const doc = this.#currentPageTrackingDocument(explicitDoc);
        if (isDocumentLike(explicitDoc) && !doc) {
            return null;
        }
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
        if (
            syncGeneration !== this.visiblePageCollectionGeneration
            || this.#currentPageTrackingDocument(doc) !== doc
        ) {
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
            const builtState = buildVisiblePageTrackingStates(
                doc,
                this.articleReadingProgress,
                visibleRange,
                visibleSegmentsResult
            );
            states = builtState.states;
            if (
                syncGeneration !== this.visiblePageCollectionGeneration
                || this.#currentPageTrackingDocument(doc) !== doc
            ) {
                return null;
            }
            this.lastPageTrackingStateSignature = pageTrackingSignature;
            this.lastPageTrackingStateSnapshot = {
                states,
                diagnostics: builtState.diagnostics,
            };
        }
        if (
            syncGeneration !== this.visiblePageCollectionGeneration
            || this.#currentPageTrackingDocument(doc) !== doc
        ) {
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
        try {
            this.navHUD?.setHideNavigationDueToScroll?.(shouldHide, source, {
                direction,
                isRTL: this.isRTL,
                ...details,
            });
        } catch (error) {
            manabiTimelineMark('pageTurn.navigationVisibility.hudError', {
                direction,
                source,
                message: error?.message || String(error),
            });
        }
        postEbookNavigationVisibilityToNative?.(shouldHide, source, {
            direction,
            isRTL: this.isRTL,
            ...details,
        });
    }
    async #runPageTurn({
        stage,
        prepare = null,
        move,
        complete = null,
        markInputSource = null,
        clearReadChromeReason = 'page-turn-start',
        deferVisiblePageResetUntilMovement = false,
        ignoreIfPageTurnInFlight = false,
        ignoreIfRendererNavigationInFlight = false,
        serializedContinuation = false,
        details = {},
    }) {
        if (this.#closed) {
            return this.#readerClosedPageTurnResult('before-reader-turn');
        }
        if (typeof move !== 'function') {
            return { ignored: true, reason: 'missingMoveHandler' };
        }
        if (this.#pageTurnInFlight && !serializedContinuation) {
            if (ignoreIfPageTurnInFlight) {
                return { ignored: true, reason: 'pageTurnInFlight' };
            }
            this.#queuedPageTurnRun?.resolve?.({
                ignored: true,
                reason: 'pageTurnQueuedSuperseded',
            });
            return await new Promise((resolve, reject) => {
                this.#queuedPageTurnRun = {
                    stage,
                    prepare,
                    move,
                    complete,
                    markInputSource,
                    clearReadChromeReason,
                    deferVisiblePageResetUntilMovement,
                    ignoreIfPageTurnInFlight,
                    ignoreIfRendererNavigationInFlight,
                    details,
                    resolve,
                    reject,
                };
            });
        }

        const startedAt = performanceNowMs();
        this.#pageTurnInFlight = true;
        let result = null;
        let restoredUncommittedTargets = false;
        let moveStarted = false;
        let visibleResetAttempted = false;
        let completionPublished = false;
        const publishCompletion = (value) => {
            if (completionPublished || typeof complete !== 'function') return;
            completionPublished = true;
            try {
                complete(value);
            } catch (error) {
                manabiTimelineMark('pageTurn.reader.run.completionError', {
                    stage,
                    markInputSource,
                    message: error?.message || String(error),
                });
            }
        };
        const completionValue = (value, movementDisposition) => {
            if (value && typeof value === 'object') return value;
            return {
                moved: movementDisposition === PAGE_TURN_MOVEMENT_DISPOSITION.moved,
                authoritativeNoMove:
                    movementDisposition === PAGE_TURN_MOVEMENT_DISPOSITION.noMove,
                movementNotOwned:
                    movementDisposition === PAGE_TURN_MOVEMENT_DISPOSITION.notOwned,
                movementUncertain:
                    movementDisposition === PAGE_TURN_MOVEMENT_DISPOSITION.unknown,
                movementDisposition,
                ...(restoredUncommittedTargets
                    ? { restoredUncommittedTargets: true }
                    : {}),
            };
        };
        try {
            const rendererOwnershipRefusedBeforeSetup =
                ignoreIfRendererNavigationInFlight
                && rendererNavigationInFlight(this.view?.renderer);
            let preparedMove;
            if (rendererOwnershipRefusedBeforeSetup) {
                result = {
                    ignored: true,
                    reason: 'rendererNavigationInFlight',
                    rendererOwnershipPhase: 'before-reader-turn',
                };
            } else {
                if (markInputSource) {
                    markRestorePositionSavePageTurnInput(markInputSource);
                }
                preparedMove = typeof prepare === 'function'
                    ? await prepare()
                    : undefined;
                if (this.#closed) {
                    result = this.#readerClosedPageTurnResult('after-prepare');
                } else {
                    const rendererOwnershipRefused =
                        ignoreIfRendererNavigationInFlight
                        && rendererNavigationInFlight(this.view?.renderer);
                    if (preparedMove?.skipMove === true) {
                        result = preparedMove.result;
                    } else if (rendererOwnershipRefused) {
                        result = {
                            ignored: true,
                            reason: 'rendererNavigationInFlight',
                            rendererOwnershipPhase: 'before-renderer-attempt',
                        };
                    } else {
                        const executeMove = async () => {
                            if (this.#closed) {
                                return this.#readerClosedPageTurnResult('before-renderer-attempt');
                            }
                            // runWithNavigationIntent enters through a promise boundary.
                            // Recheck renderer ownership inside that boundary before the
                            // destructive reset and renderer call become one attempt.
                            if (
                                ignoreIfRendererNavigationInFlight
                                && rendererNavigationInFlight(this.view?.renderer)
                            ) {
                                return {
                                    ignored: true,
                                    reason: 'rendererNavigationInFlight',
                                    rendererOwnershipPhase: 'renderer-attempt',
                                };
                            }
                            if (!deferVisiblePageResetUntilMovement) {
                                visibleResetAttempted = true;
                                this.#clearVisiblePageReadChrome(clearReadChromeReason);
                            }
                            // Errors before this point are safe, authoritative no-ops.
                            // Once the renderer is invoked, a throw can follow visible
                            // mutation or relocation and must remain ambiguous.
                            moveStarted = true;
                            return await move(preparedMove);
                        };
                        result = markInputSource
                            ? await runWithNavigationIntent({
                                source: markInputSource,
                                stage,
                                pageTurn: true,
                                ...details,
                            }, executeMove)
                            : await executeMove();
                    }
                }
            }
            if (this.#closed) {
                result = this.#readerClosedPageTurnResult('after-renderer-attempt');
            }
            const movementDisposition = pageTurnMovementDisposition(result);
            if (
                movementDisposition === PAGE_TURN_MOVEMENT_DISPOSITION.noMove
                && !deferVisiblePageResetUntilMovement
            ) {
                this.#restoreNativeLookupTargetsAfterUncommittedPageTurn(
                    `${stage}.no-move`
                );
                restoredUncommittedTargets = true;
            }
            // A tentative lookup turn never commits its reset here. A real move
            // emits renderer relocation, whose normal invalidation is the single
            // destructive commit point. This avoids clearing freshly collected
            // destination geometry if relocation settled before this promise.
            let returnValue;
            if (result && typeof result === 'object') {
                returnValue = {
                    ...result,
                    movementDisposition,
                    ...(restoredUncommittedTargets
                        ? { restoredUncommittedTargets: true }
                        : {}),
                };
            } else if (result === true || result === false) {
                returnValue = result;
            } else {
                returnValue = {
                    movementDisposition,
                    ...(restoredUncommittedTargets
                        ? { restoredUncommittedTargets: true }
                        : {}),
                };
            }
            publishCompletion(completionValue(returnValue, movementDisposition));
            return returnValue;
        } catch (error) {
            if (this.#closed) {
                const closedResult = this.#readerClosedPageTurnResult('turn-error');
                publishCompletion(closedResult);
                return closedResult;
            }
            if (!moveStarted) {
                const rendererOwnershipRefused =
                    ignoreIfRendererNavigationInFlight
                    && rendererNavigationInFlight(this.view?.renderer);
                if (rendererOwnershipRefused) {
                    const setupOwnershipResult = {
                        ignored: true,
                        moved: false,
                        movementNotOwned: true,
                        movementDisposition: PAGE_TURN_MOVEMENT_DISPOSITION.notOwned,
                        failureReason: 'rendererNavigationInFlight',
                        rendererOwnershipPhase: 'setup-error',
                        error: error?.message || String(error),
                    };
                    publishCompletion(setupOwnershipResult);
                    return setupOwnershipResult;
                }
                if (visibleResetAttempted) {
                    try {
                        this.#restoreNativeLookupTargetsAfterUncommittedPageTurn(
                            `${stage}.setup-error`
                        );
                        restoredUncommittedTargets = true;
                    } catch (_restoreError) {}
                }
                manabiTimelineMark('pageTurn.reader.run.setupError', {
                    stage,
                    markInputSource,
                    message: error?.message || String(error),
                    elapsedMs: safeRound(performanceNowMs() - startedAt, 1),
                });
                const setupErrorResult = {
                    moved: false,
                    authoritativeNoMove: true,
                    movementDisposition: PAGE_TURN_MOVEMENT_DISPOSITION.noMove,
                    failureReason: 'pageTurnSetupError',
                    error: error?.message || String(error),
                    ...(restoredUncommittedTargets
                        ? { restoredUncommittedTargets: true }
                        : {}),
                };
                publishCompletion(setupErrorResult);
                return setupErrorResult;
            }
            manabiTimelineMark('pageTurn.reader.run.error', {
                stage,
                markInputSource,
                message: error?.message || String(error),
                elapsedMs: safeRound(performanceNowMs() - startedAt, 1),
            });
            throw error;
        } finally {
            manabiTimelineMeasure('pageTurn.run', startedAt, {
                stage,
                markInputSource,
                queued: false,
                hasQueuedPageTurn: !!this.#queuedPageTurnRun,
            }, 0);
            const queuedPageTurnRun = this.#queuedPageTurnRun;
            this.#queuedPageTurnRun = null;
            if (this.#closed) {
                queuedPageTurnRun?.resolve?.(
                    this.#readerClosedPageTurnResult('queued-continuation')
                );
                this.#pageTurnInFlight = false;
            } else if (queuedPageTurnRun) {
                queueMicrotask(() => {
                    void this.#runPageTurn({
                        ...queuedPageTurnRun,
                        serializedContinuation: true,
                    })
                        .then(queuedPageTurnRun.resolve)
                        .catch(queuedPageTurnRun.reject);
                });
            } else {
                this.#pageTurnInFlight = false;
            }
        }
    }
    #restoreNativeLookupTargetsAfterUncommittedPageTurn(reason) {
        this.#scheduleNativeLookupHitTargetRefreshSettle(
            `page-turn-uncommitted:${reason}`
        );
        postNativeLookupPageTurnDisplayReady(
            `page-turn-uncommitted:${reason}`
        );
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
            : (getPrimaryRendererContent(this.view?.renderer)?.doc ?? null);
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
        const isPageTurnStart = reason === 'page-turn-start';
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
        if (this.#closed) return;
        if (retryCount <= 0) {
            return;
        }
        if (this.pageTrackingRetryHandle) {
            cancelAnimationFrame(this.pageTrackingRetryHandle);
        }
        this.pageTrackingRetryHandle = requestAnimationFrame(() => {
            this.pageTrackingRetryHandle = null;
            if (this.#closed) return;
            this.#syncPageTrackingButtons(reason, explicitDoc, retryCount - 1).catch((error) => console.error(error));
        });
    }
    #schedulePageTrackingSync(reason = 'unspecified', explicitDoc = null, retryCount = 0) {
        if (this.#closed) return;
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
            if (this.#closed) return;
            this.pageTrackingDeferredHandle = requestAnimationFrame(() => {
                this.pageTrackingDeferredHandle = null;
                if (this.#closed) return;
                this.pageTrackingDeferredFrameHandle = requestAnimationFrame(() => {
                    this.pageTrackingDeferredFrameHandle = null;
                    if (this.#closed) return;
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
        if (this.#closed) return;
        if (this.nativeMarkReadStateRefreshHandle) {
            cancelAnimationFrame(this.nativeMarkReadStateRefreshHandle);
            this.nativeMarkReadStateRefreshHandle = null;
        }
        this.nativeMarkReadStateRefreshHandle = requestAnimationFrame(() => {
            if (this.#closed) {
                this.nativeMarkReadStateRefreshHandle = null;
                return;
            }
            this.nativeMarkReadStateRefreshHandle = requestAnimationFrame(() => {
                this.nativeMarkReadStateRefreshHandle = null;
                if (this.#closed) return;
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
        if (this.#closed) return;
        if (this.#shouldDeferNativeLookupHitTargetRefresh(reason)) {
            this.#deferNativeLookupHitTargetRefresh(reason, explicitDoc);
            return;
        }
        // This refresh supersedes any request retained before the display gate opened.
        this.pendingNativeLookupHitTargetRefresh = null;
        if (this.nativeLookupHitTargetRefreshHandle) {
            cancelAnimationFrame(this.nativeLookupHitTargetRefreshHandle);
            this.nativeLookupHitTargetRefreshHandle = null;
        }
        clearTimeout(this.nativeLookupHitTargetRefreshFallbackHandle);
        this.nativeLookupHitTargetRefreshFallbackHandle = null;
        const generation = (this.nativeLookupHitTargetRefreshGeneration || 0) + 1;
        this.nativeLookupHitTargetRefreshGeneration = generation;
        const finishInitialForegroundCriticalSection =
            globalThis.__manabiFinishInitialForegroundCriticalSection;
        const runRefresh = async () => {
            if (this.#closed) return;
            const attachedDocuments = this.#lookupContentWindows()
                .map((view) => view.document)
                .filter(isDocumentLike);
            // didDisplay means Foliate has already columnized a usable page. Do not
            // hold its first lookup/status pass behind fonts.ready: remote or custom
            // fonts can settle much later, leaving the initially visible page inert.
            // The document-load font callback schedules one corrective geometry pass
            // if font metrics actually finish after this provisional pass.
            if (generation !== this.nativeLookupHitTargetRefreshGeneration) {
                return;
            }
            if (!shouldPublishForDocumentFrame({
                scheduledGeneration: generation,
                currentGeneration: this.nativeLookupHitTargetRefreshGeneration,
                explicitDocument: isDocumentLike(explicitDoc) ? explicitDoc : null,
                currentDocuments: attachedDocuments,
            })) {
                return;
            }
            this.nativeLookupHitTargetRefreshHandle = null;
            if (this.#shouldDeferNativeLookupHitTargetRefresh(reason)) {
                this.#deferNativeLookupHitTargetRefresh(reason, explicitDoc);
                return;
            }
            const currentDocs = isDocumentLike(explicitDoc)
                ? [explicitDoc]
                : attachedDocuments;
            const primaryContent = getPrimaryRendererContent(this.view?.renderer);
            const primaryDoc = primaryContent?.doc ?? primaryContent?.document ?? null;
            let primaryVisibleResult = null;
            try {
                for (const doc of currentDocs) {
                    const visibleRange = this.#visibleRangeForDocument(doc);
                    const result = this.#visiblePageSegmentResult(
                        doc,
                        visibleRange,
                        `scheduled:${reason}`,
                        { postIfCached: true }
                    );
                    if (doc === primaryDoc) {
                        primaryVisibleResult = result;
                    }
                }
                if (
                    document.body?.classList?.contains?.('loading') === true
                    && (primaryVisibleResult?.visibleSegments?.length ?? 0) > 0
                ) {
                    await this.clearLoadingForRelocatedVisibleContent(
                        `native-lookup-refresh:${reason}`,
                        primaryVisibleResult
                    );
                }
            } finally {
                // reader.open() resolves before WebKit's first didDisplay/columnization pass.
                // Keep noncritical native work suppressed through this first visible target and
                // status refresh, which is the deterministic point at which the page is ready
                // for interaction. Later page refreshes find no active initial-load lease.
                if (
                    !this.#closed
                    && generation === this.nativeLookupHitTargetRefreshGeneration
                ) {
                    finishInitialForegroundCriticalSection?.(
                        `nativeLookupRefresh.completed:${reason}`
                    );
                }
            }
        };
        let didRun = false;
        let fallbackHandle = null;
        const runOnce = () => {
            if (didRun) return;
            didRun = true;
            if (this.nativeLookupHitTargetRefreshHandle != null) {
                cancelAnimationFrame(this.nativeLookupHitTargetRefreshHandle);
                this.nativeLookupHitTargetRefreshHandle = null;
            }
            if (fallbackHandle != null) {
                clearTimeout(fallbackHandle);
                if (this.nativeLookupHitTargetRefreshFallbackHandle === fallbackHandle) {
                    this.nativeLookupHitTargetRefreshFallbackHandle = null;
                }
                fallbackHandle = null;
            }
            void runRefresh();
        };
        fallbackHandle = setTimeout(runOnce, 250);
        this.nativeLookupHitTargetRefreshFallbackHandle = fallbackHandle;
        this.nativeLookupHitTargetRefreshHandle = typeof requestAnimationFrame === 'function'
            ? requestAnimationFrame(runOnce)
            : null;
    }
    #shouldDeferNativeLookupHitTargetRefresh(reason = 'unspecified') {
        if (reason === 'manual') {
            return false;
        }
        return globalThis.__manabiRestoreInProgress === true
            || (
                document.body?.classList?.contains?.('loading') === true
                && this.hasReachedLoadingDidDisplayBoundary !== true
            )
            || this.hasCompletedLastPositionLoadAttempt !== true;
    }
    #deferNativeLookupHitTargetRefresh(reason = 'unspecified', explicitDoc = null) {
        this.pendingNativeLookupHitTargetRefresh = {
            reason,
            explicitDoc: isDocumentLike(explicitDoc) && this.hasCompletedLastPositionLoadAttempt === true ? explicitDoc : null,
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
    completeLastPositionLoadAttempt(reason = 'unspecified') {
        this.hasCompletedLastPositionLoadAttempt = true;
        // didDisplay may have deferred visible lookup/status enrichment until the
        // restore attempt became terminal. Flush at that state transition;
        // otherwise a failed restore leaves the terminal visible page inert.
        this.#flushPendingNativeLookupHitTargetRefresh(`last-position-attempt-completed:${reason}`);
    }
    completeLastPositionLoad(reason = 'unspecified') {
        this.hasLoadedLastPosition = true;
        this.completeLastPositionLoadAttempt(reason);
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
    async #waitForAnimationFrames(count = 1) {
        const frameCount = Math.max(0, Number(count) || 0);
        for (let index = 0; index < frameCount; index += 1) {
            await new Promise((resolve) => requestAnimationFrame(() => resolve()));
        }
    }
    async #settleInitialPaginatorLayout(reason = 'unknown', { force = false, forceRender = false } = {}) {
        if (this.#closed) {
            return { rendered: false, reason: 'reader-closed' };
        }
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
            if (this.#closed || this.view?.renderer !== renderer) {
                return { rendered: false, reason: 'reader-closed' };
            }
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
        if (this.#closed) return;
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
            if (this.#closed) return;
            await this.#settleInitialPaginatorLayout(reason);
        });
    }
    async #advanceAfterMarkRead(owner) {
        await new Promise((resolve) => setTimeout(resolve, 430));
        if (
            !owner
            || !this.#isRendererLifecycleCurrent(owner.lifecycleGeneration, owner.renderer)
            || this.visiblePageCollectionGeneration !== owner.visiblePageCollectionGeneration
        ) {
            return false;
        }
        if (this.isRTL) {
            return await this.view?.goLeft?.() === true;
        } else {
            return await this.view?.goRight?.() === true;
        }
    }
    #releaseSideNavChevronHoverSuppression(key) {
        const cleanup = this.#chevronHoverSuppressionCleanup[key];
        this.#chevronHoverSuppressionCleanup[key] = null;
        cleanup?.();
    }
    #resetSideNavChevronAnimation(icon, key) {
        if (this.#chevronFadeAnimationFrames[key] !== null) {
            cancelAnimationFrame(this.#chevronFadeAnimationFrames[key]);
            this.#chevronFadeAnimationFrames[key] = null;
        }
        this.#chevronFadeAnimationCleanup[key]?.();
        this.#chevronFadeAnimationCleanup[key] = null;
        this.#releaseSideNavChevronHoverSuppression(key);
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
        let releaseHoverSuppression = null;
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
            releaseHoverSuppression?.();
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
                if (button) {
                    let released = false;
                    const release = () => {
                        if (released) return;
                        released = true;
                        button.classList.remove('suppress-hover-chevron');
                        button.removeEventListener('pointerleave', clearHoverSuppression);
                        button.removeEventListener('mouseleave', clearHoverSuppression);
                        button.removeEventListener('blur', clearHoverSuppression);
                        document.removeEventListener('pointermove', clearHoverSuppression, true);
                        if (this.#chevronHoverSuppressionCleanup[key] === release) {
                            this.#chevronHoverSuppressionCleanup[key] = null;
                        }
                    };
                    releaseHoverSuppression = release;
                    this.#chevronHoverSuppressionCleanup[key] = release;
                    button.addEventListener('pointerleave', clearHoverSuppression);
                    button.addEventListener('mouseleave', clearHoverSuppression);
                    button.addEventListener('blur', clearHoverSuppression);
                    document.addEventListener('pointermove', clearHoverSuppression, true);
                }
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
        if (Math.abs(dx) <= minSwipe) return;
        state.triggered = true;
        this.#fadeSideNavChevronAfterFullOpacity(chevronSide);
        await this.#runPageTurn({
            stage: 'pageTurn.mainDocumentSwipe',
            markInputSource: `pageTurn.mainDocumentSwipe.${logicalDirection}`,
            clearReadChromeReason: 'page-turn-swipe-intent',
            ignoreIfRendererNavigationInFlight: true,
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
                ? await this.view?.next?.(undefined, {
                    ignoreIfNavigationInFlight: true,
                })
                : await this.view?.prev?.(undefined, {
                    ignoreIfNavigationInFlight: true,
                }),
        });
    }
    #onMainDocumentTouchEnd(_event) {
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
        if (this.#closed) throw readerOpenSupersededError()
        const lifecycleGeneration = ++this.#lifecycleGeneration
        const isCurrent = () => this.#isLifecycleCurrent(lifecycleGeneration)
        this.setLoadingIndicator(true, 'reader.open');
        installReaderPresentationState(options?.readerPresentationState ?? globalThis.__manabiReaderPresentationState, 'reader.open');

        this.hasCompletedLastPositionLoadAttempt = false
        this.hasLoadedLastPosition = false
        this.hasReachedLoadingDidDisplayBoundary = false
        this.#resetInitialDisplaySettledPromise();
        this.lastCFIPersistenceObservation = null;
        this.unstableCFIs.clear();
        this.#lastPublishedCurrentContentPageKey = null;
        if (this.initialPaginatorSettleHandle) {
            cancelAnimationFrame(this.initialPaginatorSettleHandle);
            this.initialPaginatorSettleHandle = null;
        }
        this.hasSettledInitialPaginatorLayout = false;
        const view = await getView(file, {
            isCurrent,
            onViewCreated: candidate => {
                if (isCurrent()) this.view = candidate
            },
        })
        if (!isCurrent() || this.view !== view) {
            view.close?.()
            view.remove?.()
            throw readerOpenSupersededError()
        }
        const initialRestore = options?.initialRestore ?? null;
        globalThis.__manabiPostReaderDocStateEvent?.('reader.open.viewAssigned');
        // this.view.renderer.setAttribute('animated', true) // Flows top to bottom instead of like a book...
        if (typeof window.initialLayoutMode !== 'undefined') {
            this.view.renderer.setAttribute('flow', window.initialLayoutMode)
        }
        this.#installVisibleRendererGoToGuard();
        this.#listen(this.view.renderer, 'goTo', this.#onGoTo.bind(this))
        this.#listen(this.view.renderer, 'didDisplay', this.#onDidDisplay.bind(this))
        this.#listen(this.view, 'load', this.#onLoad.bind(this))
        this.#listen(this.view, 'document-committed', this.#onDocumentCommitted.bind(this))
        this.#listen(this.view, 'document-unload', this.#onDocumentUnload.bind(this))
        this.#listen(this.view, 'relocate', this.#onRelocate.bind(this))

        const {
            book
        } = this.view
        this.bookDir = book.dir || 'ltr';
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
                                            this.#listen(btn, 'click', this.#onNavButtonClick.bind(this))
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
                ignoreIfRendererNavigationInFlight: true,
                details: {
                    side,
                    method,
                    eventType,
                },
                move: async () => method === 'goLeft'
                    ? await this.view.goLeft({ ignoreIfNavigationInFlight: true })
                    : await this.view.goRight({ ignoreIfNavigationInFlight: true }),
            });
        };
        const leftSideBtn = document.getElementById('btn-scroll-left');
        this.#listen(leftSideBtn, 'click', async () => {
            const now = Date.now();
            if (globalThis.__manabiLastSideButtonTouchActivation?.side === 'left'
                && now - globalThis.__manabiLastSideButtonTouchActivation.timestamp < 700) {
                return;
            }
            await runSideButtonPageTurn('left', 'goLeft', leftSideBtn, 'click');
        });
        const rightSideBtn = document.getElementById('btn-scroll-right');
        this.#listen(rightSideBtn, 'click', async () => {
            const now = Date.now();
            if (globalThis.__manabiLastSideButtonTouchActivation?.side === 'right'
                && now - globalThis.__manabiLastSideButtonTouchActivation.timestamp < 700) {
                return;
            }
            await runSideButtonPageTurn('right', 'goRight', rightSideBtn, 'click');
        });

        // Immediate tap feedback for side-nav chevrons on iOS/touch
        document.querySelectorAll('.side-nav').forEach(nav => {
            this.#listen(nav, 'touchstart', () => {
                if (nav.disabled || isCompactNavigationSheetSidePaginationDisabled()) return;
                nav.classList.add('pressed');
            }, {
                passive: true
            });
            this.#listen(nav, 'touchend', (event) => {
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
            this.#listen(nav, 'touchcancel', () => {
                nav.classList.remove('pressed');
            });
        });

        // Side-nav opacity wiring
        this.#listen(this.view, 'sideNavChevronOpacity', e => {
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
        this.#listen(document, 'resetSideNavChevrons', () => {
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

        this.#listen(percentInput, 'input', () => {
            const value = parseFloat(percentInput.value);
            const valid = !isNaN(value) && value >= 0 && value <= 100 && value !== this.lastPercentValue;
            percentButton.disabled = !valid;
        });

        this.#listen(percentButton, 'click', () => {
            const value = parseFloat(percentInput.value);
            if (!isNaN(value) && value >= 0 && value <= 100) {
                this.lastPercentValue = value;
                percentButton.disabled = true;
                this.goToPercent(value, 'sidebar-percent-jump-button');
            }
        });

        this.#listen(document, 'keydown', this.#handleKeydown.bind(this))

        let pendingMainDocumentBlankNavigationTouch = null;
        let lastPostedMainDocumentBlankTouchTap = null;
        const shouldSuppressMainDocumentSyntheticMouseBlankTap = (event) => {
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
            if (shouldSuppressMainDocumentSyntheticMouseBlankTap(event)) {
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
        this.#listen(document, 'touchstart', processNavChromeTouchStart, {
            passive: true
        })
        this.#listen(document, 'mousedown', processNavChromeTouchStart, {
            passive: true
        })
        this.#listen(document, 'touchstart', processPageTrackingChromeTouchStart, {
            passive: true
        })
        this.#listen(document, 'mousedown', processPageTrackingChromeTouchStart, {
            passive: true
        })
        this.#listen(document, 'touchmove', processChromeBlankNavigationTouchMove, {
            passive: true
        })
        this.#listen(document, 'touchend', processChromeBlankNavigationTouchEnd, {
            passive: true
        })
        this.#listen(document, 'touchcancel', processChromeBlankNavigationTouchEnd, {
            passive: true
        })
        this.#listen(document, 'touchstart', processTouchStart, {
            passive: true
        })
        this.#listen(document, 'touchmove', processMainDocumentBlankNavigationTouchMove, {
            passive: true
        })
        this.#listen(document, 'touchend', processMainDocumentBlankNavigationTouchEnd, {
            passive: true
        })
        this.#listen(document, 'touchcancel', processMainDocumentBlankNavigationTouchEnd, {
            passive: true
        })
        this.#listen(document, 'mousedown', processTouchStart, {
            passive: true
        })
        this.#listen(document, 'touchstart', this.#onMainDocumentTouchStart.bind(this), {
            passive: true,
        });
        this.#listen(document, 'touchmove', this.#onMainDocumentTouchMove.bind(this), {
            passive: false,
        });
        this.#listen(document, 'touchend', this.#onMainDocumentTouchEnd.bind(this), {
            passive: true,
        });
        this.#listen(document, 'touchcancel', this.#onMainDocumentTouchEnd.bind(this), {
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
        if (!isCurrent()) throw readerOpenSupersededError()
        this.#schedulePostInitialOpenWork(book, lifecycleGeneration);
    }

    #schedulePostInitialOpenWork(book, lifecycleGeneration) {
        clearTimeout(this.#postInitialOpenWorkHandle)
        this.#postInitialOpenWorkHandle = setTimeout(() => {
            this.#postInitialOpenWorkHandle = null
            if (!this.#isLifecycleCurrent(lifecycleGeneration)) return
            void this.#runPostInitialOpenWork(book, lifecycleGeneration).catch((error) => {
                if (error?.code !== 'reader-open-superseded') console.error(error);
            });
        }, 0);
    }

    async #runPostInitialOpenWork(book, lifecycleGeneration) {
        if (!this.#isLifecycleCurrent(lifecycleGeneration)) return
        const toc = book.toc
        if (toc && !this.#tocView) {
            this.#tocView = createTOCView(toc, async (href) => {
                if (!this.#isLifecycleCurrent(lifecycleGeneration)) return;
                await runWithNavigationIntent({
                    source: 'toc',
                    target: 'view.goTo',
                    href,
                }, () => this.view.goTo(href)).catch(e => console.error(e))
                if (!this.#isLifecycleCurrent(lifecycleGeneration)) return;
                this.closeSideBar()
            })
            $('#toc-view').append(this.#tocView.element)
        }

        // load and show highlights embedded in the file by Calibre
        let bookmarks;
        try {
            bookmarks = await book.getCalibreBookmarks?.()
        } catch {
            return;
        }
        if (!this.#isLifecycleCurrent(lifecycleGeneration)) return
        if (bookmarks) {
            const {
                fromCalibreHighlight
            } = await import('./epubcfi.js')
            if (!this.#isLifecycleCurrent(lifecycleGeneration)) return
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
            this.#listen(this.view, 'create-overlay', e => {
                const {
                    index
                } = e.detail
                const list = this.annotations.get(index)
                if (list)
                    for (const annotation of list)
                        this.view.addAnnotation(annotation)
                        })
            this.#listen(this.view, 'draw-annotation', e => {
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
            this.#listen(this.view, 'show-annotation', e => {
                const annotation = this.annotationsByValue.get(e.detail.value)
                if (annotation.note) alert(annotation.note)
                    })
        }
    }

    async #displayInitialSection(reason = 'reader.open', initialRestore = null) {
        const lifecycleGeneration = this.#lifecycleGeneration;
        const initialDisplayGeneration = ++this.#initialDisplayGeneration;
        const isCurrentInitialDisplay = () => this.#isLifecycleCurrent(lifecycleGeneration)
            && this.#initialDisplayGeneration === initialDisplayGeneration;
        if (!isCurrentInitialDisplay()) return false;
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
            if (!isCurrentInitialDisplay()) return null;
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
            if (!isCurrentInitialDisplay()) {
                return {
                    ok: false,
                    superseded: true,
                };
            }
            const navigationIntent = beginNavigationIntent(intent);
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
                        if (!isCurrentInitialDisplay()) return result;
                        this.initialDisplayNavigationPending = false;
                        this.#settleInitialDisplayFromVisibleContent(`${reason}.initialDisplay.operationComplete`);
                        return {
                            settledBy: 'operation',
                            result,
                        };
                    })
                    .catch((error) => {
                        if (!isCurrentInitialDisplay()) return;
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
                    navigationIntent.release();
                });
                if (operationResult && typeof operationResult.then !== 'function') {
                    if (!isCurrentInitialDisplay()) {
                        navigationIntent.release();
                        return {
                            ok: false,
                            superseded: true,
                        };
                    }
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
                navigationIntent.release();
                if (!isCurrentInitialDisplay()) {
                    return {
                        ok: false,
                        superseded: true,
                    };
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
            if (!isCurrentInitialDisplay() || navigationResult?.superseded === true) {
                return false;
            }
            // With no saved locator, successfully dispatching the first-section navigation
            // makes the position authoritative immediately. Keeping the restore gate closed
            // here permanently defers initial lookup targets and tracking highlights because
            // there is no later native loadLastPosition call required to release it.
            if (!hasInitialRestoreTarget && navigationResult?.ok === true) {
                this.completeLastPositionLoad('initial-display-no-restore-target');
                if (!isCurrentInitialDisplay()) return false;
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
            if (!isCurrentInitialDisplay()) return false;
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
            }
            return true;
        } catch (error) {
            if (!isCurrentInitialDisplay()) return false;
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

    async updateNavButtons({ relocateSequence = null } = {}) {
        const lifecycleGeneration = this.#lifecycleGeneration;
        const r = this.view?.renderer ?? null;
        const isCurrentUpdate = () =>
            this.#isRendererLifecycleCurrent(lifecycleGeneration, r)
            && (
                !Number.isInteger(relocateSequence)
                || relocateSequence === this.#relocateSequence
            );
        if (!r || !isCurrentUpdate()) return false;
        // The exact renderer promise or its bounded fallback owns chapter-
        // navigation completion. An older relocation continuation must not
        // finish a newer button operation that began while it was suspended.
        if (this.#navButtonOperations.size > 0) {
            return false;
        }
        const pageMetrics = typeof r.pageMetrics === "function" ? await r.pageMetrics() : null;
        if (!isCurrentUpdate()) return false;
        // Use new section start/end helpers if available
        const atSectionStart = pageMetrics
            ? pageMetrics.page <= 1
            : (typeof r.isAtSectionStart === "function" ? await r.isAtSectionStart() : false);
        if (!isCurrentUpdate()) return false;
        const atSectionEnd = pageMetrics
            ? pageMetrics.page >= pageMetrics.pages - 2
            : (typeof r.isAtSectionEnd === "function" ? await r.isAtSectionEnd() : false);
        if (!isCurrentUpdate()) return false;
        // Use public helpers to detect prev/next section
        const hasPrevSection = typeof r.getHasPrevSection === "function" ? await r.getHasPrevSection() : true;
        if (!isCurrentUpdate()) return false;
        const hasNextSection = typeof r.getHasNextSection === "function" ? await r.getHasNextSection() : true;
        if (!isCurrentUpdate()) return false;
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
            this.#invalidateCompletionAction();
        }

        this.#show(this.buttons.prev, atSectionStart && hasPrevSection);

        if (atSectionEnd && hasNextSection) {
            this.#show(this.buttons.next, true);
        } else {
            this.#show(this.buttons.next, false);
        }
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
        return true;
    }
    async #physicalPagePositionSnapshot() {
        const renderer = this.view?.renderer;
        if (!renderer) {
            return null;
        }
        const metrics = typeof renderer.pageMetrics === 'function'
            ? await renderer.pageMetrics().catch(() => null)
            : null;
        return {
            index: getPrimaryRendererContentIndex(renderer),
            sectionIndex: Number.isFinite(this.view?.lastLocation?.sectionIndex)
                ? this.view.lastLocation.sectionIndex
                : null,
            page: Number.isFinite(metrics?.page) ? metrics.page : null,
            start: Number.isFinite(metrics?.start) ? metrics.start : null,
        };
    }
    #physicalPagePositionChanged(before, after) {
        if (!before || !after) {
            return null;
        }
        const comparablePairs = [
            [before.index, after.index],
            [before.sectionIndex, after.sectionIndex],
            [before.page, after.page],
        ].filter(([first, second]) => (
            Number.isFinite(first) && Number.isFinite(second)
        ));
        if (comparablePairs.some(([first, second]) => first !== second)) {
            return true;
        }
        if (Number.isFinite(before.start) && Number.isFinite(after.start)) {
            return Math.abs(after.start - before.start) >= 1;
        }
        return comparablePairs.length > 0 ? false : null;
    }
    async #handleKeydownDetailed(event, navigationDetails = {}, serializedCompletion = null) {
        const detailedResult = ({ movementDisposition, ...details }) => ({
            moved: movementDisposition === PAGE_TURN_MOVEMENT_DISPOSITION.moved,
            authoritativeNoMove:
                movementDisposition === PAGE_TURN_MOVEMENT_DISPOSITION.noMove,
            movementNotOwned:
                movementDisposition === PAGE_TURN_MOVEMENT_DISPOSITION.notOwned,
            movementUncertain:
                movementDisposition === PAGE_TURN_MOVEMENT_DISPOSITION.unknown,
            movementDisposition,
            ...details,
        });
        let serializedCompletionPublished = false;
        const publishSerializedCompletion = (result) => {
            if (
                serializedCompletionPublished
                || typeof serializedCompletion !== 'function'
            ) {
                return result;
            }
            serializedCompletionPublished = true;
            try {
                serializedCompletion(result);
            } catch (error) {
                manabiTimelineMark('pageTurn.keydown.completionError', {
                    message: error?.message || String(error),
                });
            }
            return result;
        };

        const k = event.key;
        const renderer = this.view?.renderer;
        if (!renderer) {
            return publishSerializedCompletion(detailedResult({
                movementDisposition: PAGE_TURN_MOVEMENT_DISPOSITION.noMove,
                failureReason: 'missingRenderer',
            }));
        }
        const isRTL = this.isRTL;
        const method = k === 'ArrowLeft' || k === 'h'
            ? 'goLeft'
            : (k === 'ArrowRight' || k === 'l' ? 'goRight' : null);
        if (!method) {
            return publishSerializedCompletion(detailedResult({
                movementDisposition: PAGE_TURN_MOVEMENT_DISPOSITION.noMove,
                failureReason: 'unsupportedDirection',
            }));
        }

        const ignoreIfPageTurnInFlight = navigationDetails.ignoreIfPageTurnInFlight === true;
        const deferVisiblePageResetUntilMovement =
            navigationDetails.deferVisiblePageResetUntilMovement === true;
        const rendererBusyResult = (phase) => detailedResult({
            movementDisposition: PAGE_TURN_MOVEMENT_DISPOSITION.notOwned,
            failureReason: 'rendererNavigationInFlight',
            rendererOwnershipPhase: phase,
        });
        const turnResult = await this.#runPageTurn({
            stage: 'pageTurn.keydown',
            markInputSource: `pageTurn.keydown.${k}`,
            deferVisiblePageResetUntilMovement,
            ignoreIfPageTurnInFlight,
            ignoreIfRendererNavigationInFlight: true,
            complete: publishSerializedCompletion,
            details: {
                key: k,
                method,
                isRTL,
                ...navigationDetails,
            },
            // Renderer ownership is checked on both sides of the asynchronous
            // metrics read. Once the second check succeeds, target invalidation
            // and renderer invocation run synchronously in the same task.
            prepare: async () => {
                if (rendererNavigationInFlight(renderer)) {
                    return {
                        skipMove: true,
                        result: rendererBusyResult('before-position-snapshot'),
                    };
                }
                const positionBeforeTurn = await this.#physicalPagePositionSnapshot();
                if (rendererNavigationInFlight(renderer)) {
                    return {
                        skipMove: true,
                        result: rendererBusyResult('after-position-snapshot'),
                    };
                }
                return {
                    positionBeforeTurn,
                    displaySettledSequenceBeforeTurn: this.displaySettledSequence,
                };
            },
            move: async ({
                positionBeforeTurn,
                displaySettledSequenceBeforeTurn,
            } = {}) => {
                const turnOptions = {
                    ignoreIfPageTurnInFlight,
                    ignoreIfNavigationInFlight: true,
                };
                const moveResult = method === 'goLeft'
                    ? await this.view.goLeft(turnOptions)
                    : await this.view.goRight(turnOptions);
                const receiptDisposition = pageTurnMovementDisposition(moveResult);
                if (receiptDisposition !== PAGE_TURN_MOVEMENT_DISPOSITION.unknown) {
                    return detailedResult({
                        movementDisposition: receiptDisposition,
                        moveResult,
                        positionBeforeTurn,
                        positionAfterTurn: null,
                        settledPositionAfterTurn: null,
                        displaySettledSequenceBeforeTurn,
                        failureReason: receiptDisposition === PAGE_TURN_MOVEMENT_DISPOSITION.notOwned
                            ? (moveResult?.reason || 'pageTurnNotOwned')
                            : null,
                    });
                }

                const positionAfterTurn = await this.#physicalPagePositionSnapshot();
                const immediatePositionChanged = this.#physicalPagePositionChanged(
                    positionBeforeTurn,
                    positionAfterTurn
                );
                if (immediatePositionChanged === true) {
                    return detailedResult({
                        movementDisposition: PAGE_TURN_MOVEMENT_DISPOSITION.moved,
                        moveResult,
                        positionBeforeTurn,
                        positionAfterTurn,
                        settledPositionAfterTurn: positionAfterTurn,
                        displaySettledSequenceBeforeTurn,
                    });
                }

                // Unknown renderer receipts may settle one frame after their
                // promise. Observe once, but unchanged metrics remain ambiguous;
                // they are not proof of a terminal edge.
                await this.#waitForAnimationFrames(1);
                const settledPositionAfterTurn = await this.#physicalPagePositionSnapshot();
                const movementDisposition = observedPageTurnMovementDisposition({
                    moveResult,
                    immediatePositionChanged,
                    settledPositionChanged: this.#physicalPagePositionChanged(
                        positionBeforeTurn,
                        settledPositionAfterTurn
                    ),
                });
                return detailedResult({
                    movementDisposition,
                    moveResult,
                    positionBeforeTurn,
                    positionAfterTurn,
                    settledPositionAfterTurn,
                    displaySettledSequenceBeforeTurn,
                    failureReason: movementDisposition === PAGE_TURN_MOVEMENT_DISPOSITION.unknown
                        ? 'pageTurnMovementUncertain'
                        : null,
                });
            },
        });
        if (turnResult?.ignored === true) {
            return publishSerializedCompletion(detailedResult({
                movementDisposition: PAGE_TURN_MOVEMENT_DISPOSITION.notOwned,
                failureReason: turnResult.reason || 'pageTurnIgnored',
                pageTurnRunResult: turnResult,
            }));
        }
        return publishSerializedCompletion(turnResult ?? detailedResult({
            movementDisposition: PAGE_TURN_MOVEMENT_DISPOSITION.unknown,
            failureReason: 'missingTurnResult',
        }));
    }
    async #handleKeydown(event, navigationDetails = {}) {
        const result = await this.#handleKeydownDetailed(event, navigationDetails);
        return result?.moved === true;
    }
    async #handlePhysicalArrowKeyDetailed(
        direction,
        navigationDetails = {},
        serializedCompletion = null
    ) {
        const key = direction === 'left'
            ? 'ArrowLeft'
            : direction === 'right'
                ? 'ArrowRight'
                : null;
        if (!key) {
            return {
                moved: false,
                authoritativeNoMove: true,
                movementDisposition: PAGE_TURN_MOVEMENT_DISPOSITION.noMove,
                failureReason: 'unsupportedDirection',
            };
        }
        return await this.#handleKeydownDetailed(
            { key },
            navigationDetails,
            serializedCompletion
        );
    }
    async handlePhysicalArrowKey(direction, navigationDetails = {}) {
        const result = await this.#handlePhysicalArrowKeyDetailed(
            direction,
            navigationDetails
        );
        return result?.moved === true;
    }
    #lookupContentWindows(preferredContentIndex = null) {
        const renderer = this.view?.renderer;
        const contents = activeRendererContentsForLookup(renderer);
        const exactContents = Number.isFinite(preferredContentIndex)
            ? contents.filter((content) => content?.index === preferredContentIndex)
            : [];
        return (exactContents.length > 0 ? exactContents : contents)
            .map((content) =>
                content?.doc?.defaultView
                || content?.document?.defaultView
                || null
            )
            .filter((view) => view && !isCacheWarmerDocument(view.document));
    }
    async #turnLookupNavigationPage(direction) {
        const renderer = this.view?.renderer;
        if (!renderer || !this.view) {
            return {
                moved: false,
                authoritativeNoMove: true,
                movementDisposition: PAGE_TURN_MOVEMENT_DISPOSITION.noMove,
                failureReason: 'missingRenderer',
            };
        }
        const normalizedDirection = direction === 'previous' ? 'previous' : 'next';
        const movesLeft = normalizedDirection === 'next' ? this.isRTL : !this.isRTL;
        const physicalDirection = movesLeft ? 'left' : 'right';
        const detailedTurnResult = await this.#handlePhysicalArrowKeyDetailed(
            physicalDirection,
            {
                deferVisiblePageResetUntilMovement: true,
                ignoreIfPageTurnInFlight: true,
            },
            (result) => {
                if (result?.moved === true) {
                    this.#applyLogicalPageTurnNavigationVisibility(
                        normalizedDirection === 'next' ? 'forward' : 'backward',
                        'lookup-navigation.page'
                    );
                    return;
                }
                if (
                    pageTurnMovementDisposition(result)
                        === PAGE_TURN_MOVEMENT_DISPOSITION.noMove
                    && result?.restoredUncommittedTargets !== true
                ) {
                    postNativeLookupPageTurnDisplayReady(
                        'lookup-navigation.terminal-edge'
                    );
                }
            }
        );
        const moved = detailedTurnResult?.moved === true;
        const movementDisposition = pageTurnMovementDisposition(detailedTurnResult);
        return {
            moved,
            movementDisposition,
            authoritativeNoMove:
                movementDisposition === PAGE_TURN_MOVEMENT_DISPOSITION.noMove,
            movementNotOwned:
                movementDisposition === PAGE_TURN_MOVEMENT_DISPOSITION.notOwned,
            movementUncertain:
                movementDisposition === PAGE_TURN_MOVEMENT_DISPOSITION.unknown,
            mode: 'physicalArrowKey',
            physicalDirection,
            failureReason: moved
                ? null
                : (detailedTurnResult?.failureReason
                    || (movementDisposition === PAGE_TURN_MOVEMENT_DISPOSITION.unknown
                        ? 'pageTurnMovementUncertain'
                        : 'pageTurnNotHandled')),
            positionBeforeTurn: detailedTurnResult?.positionBeforeTurn ?? null,
            positionAfterTurn: detailedTurnResult?.positionAfterTurn ?? null,
            settledPositionAfterTurn: detailedTurnResult?.settledPositionAfterTurn ?? null,
            displaySettledSequenceBeforeTurn:
                detailedTurnResult?.displaySettledSequenceBeforeTurn ?? null,
            restoredUncommittedTargets:
                detailedTurnResult?.restoredUncommittedTargets === true,
        };
    }
    async performLookupNavigationPageTurn(request = {}) {
        const kind = request.kind === 'sentence' || request.kind === 'section'
            ? request.kind
            : 'word';
        const direction = request.direction === 'previous' ? 'previous' : 'next';
        const navigationToken = typeof request.navigationToken === 'string' && request.navigationToken.length > 0
            ? request.navigationToken
            : null;
        postNativeLookupPageTurnAttemptStarted('lookup-navigation', navigationToken);
        let turnResult;
        try {
            turnResult = await this.#turnLookupNavigationPage(direction);
        } catch (error) {
            turnResult = {
                moved: false,
                movementDisposition: PAGE_TURN_MOVEMENT_DISPOSITION.unknown,
                movementUncertain: true,
                failureReason: 'pageTurnError',
                error: error?.message || String(error),
            };
        }
        const moved = turnResult?.moved === true;
        const movementDisposition = pageTurnMovementDisposition(turnResult);
        if (!moved) {
            return {
                opened: false,
                pageTurnAttempted: true,
                pageTurnRequested: false,
                moved: false,
                movementDisposition,
                failureReason: turnResult?.failureReason
                    || (movementDisposition === PAGE_TURN_MOVEMENT_DISPOSITION.unknown
                        ? 'pageTurnMovementUncertain'
                        : 'pageTurnDidNotMove'),
                kind,
                direction,
                navigationToken,
                turnResult,
            };
        }
        return {
            opened: false,
            pageTurnAttempted: true,
            pageTurnRequested: true,
            moved: true,
            movementDisposition: PAGE_TURN_MOVEMENT_DISPOSITION.moved,
            failureReason: null,
            kind,
            direction,
            navigationToken,
            turnResult,
        };
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
        let timeoutHandle = null;
        try {
            const result = await (
                Number.isFinite(timeoutMs) && timeoutMs > 0
                    ? Promise.race([
                        this.initialDisplaySettledPromise,
                        new Promise((_, reject) => {
                            timeoutHandle = setTimeout(() => {
                                reject(new Error(`Timed out waiting for ${reason} after ${timeoutMs}ms`));
                            }, timeoutMs);
                        }),
                    ])
                    : this.initialDisplaySettledPromise
            );
            return {
                settled: true,
                ...result,
            };
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
        const activeContents = activeRendererContentsForLookup(renderer);
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
    async clearLoadingForRelocatedVisibleContent(reason = 'unspecified', visibleSegmentsResult = null) {
        if (!document.body?.classList?.contains?.('loading')) {
            return { cleared: false, reason: 'not-loading' };
        }
        const content = getPrimaryRendererContent(this.view?.renderer);
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
        const collectionGeneration = this.visiblePageCollectionGeneration;
        await this.#waitForAnimationFrames(1);
        const currentContent = getPrimaryRendererContent(this.view?.renderer);
        const currentDoc = currentContent?.doc ?? currentContent?.document ?? null;
        if (currentDoc !== doc || collectionGeneration !== this.visiblePageCollectionGeneration) {
            return { cleared: false, reason: 'stale-visible-content' };
        }
        if (!document.body?.classList?.contains?.('loading')) {
            return { cleared: false, reason: 'already-cleared' };
        }
        const clearReason = `relocate.visible-content:${reason}`;
        this.setLoadingIndicator(false, clearReason, { paintCommitted: true });
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
        let timeoutHandle = null;
        let waiter = null;
        try {
            const result = await new Promise((resolve, reject) => {
                waiter = { resolve, reject };
                this.displaySettledWaiters.push(waiter);
                if (Number.isFinite(timeoutMs) && timeoutMs > 0) {
                    timeoutHandle = setTimeout(() => {
                        this.displaySettledWaiters = this.displaySettledWaiters.filter((item) => item !== waiter);
                        reject(new Error(`Timed out waiting for ${reason} after ${timeoutMs}ms`));
                    }, timeoutMs);
                }
            });
            return result;
        } finally {
            clearTimeout(timeoutHandle);
        }
    }
    #onGoTo(event = {}) {
        if (this.#closed) return;
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
        if (this.#closed) return;
        const lifecycleGeneration = this.#lifecycleGeneration;
        const renderer = this.view?.renderer ?? null;
        const visiblePageCollectionGeneration = this.visiblePageCollectionGeneration;
        const didDisplaySequence = ++this.#didDisplaySequence;
        const isCurrentDidDisplay = () =>
            this.#isRendererLifecycleCurrent(lifecycleGeneration, renderer)
            && this.#didDisplaySequence === didDisplaySequence
            && this.visiblePageCollectionGeneration === visiblePageCollectionGeneration;
        const shouldSkipSameIndexDidDisplay =
            (this.sameIndexGoToDidDisplaySkips || 0) > 0
            && !document.body?.classList?.contains?.('loading');
        if (shouldSkipSameIndexDidDisplay) {
            this.sameIndexGoToDidDisplaySkips = Math.max(0, (this.sameIndexGoToDidDisplaySkips || 0) - 1);
            this.#resolveInitialDisplaySettled('didDisplay.skipSameIndex');
            return;
        }
        let initialSettleResult = null;
        let postFrameSettleResult = null;
        try {
            applyStoredChromeInsets('reader.didDisplay');
            initialSettleResult = await this.#settleInitialPaginatorLayout('did-display.pre-clear', {
                allowWhileLoading: true,
            });
            if (!isCurrentDidDisplay()) return;
            const shouldRunPostFrameSettle =
                MANABI_ENABLE_DID_DISPLAY_POST_FRAME_SETTLE
                && (
                initialSettleResult?.rendered === true
                || initialSettleResult?.reason === 'error'
                );
            if (shouldRunPostFrameSettle) {
                await this.#waitForAnimationFrames(2);
                if (!isCurrentDidDisplay()) return;
                postFrameSettleResult = await this.#settleInitialPaginatorLayout('did-display.pre-clear.post-frame', {
                    allowWhileLoading: true,
                    force: true,
                });
                if (!isCurrentDidDisplay()) return;
            } else {
                postFrameSettleResult = {
                    rendered: false,
                    reason: MANABI_ENABLE_DID_DISPLAY_POST_FRAME_SETTLE
                        ? 'initial-settle-stable'
                        : 'post-frame-settle-disabled',
                };
            }
        } catch (error) {
            postFrameSettleResult = {
                rendered: false,
                reason: 'did-display-error',
                message: error?.message ?? String(error),
            };
            console.error(error);
        }
        if (!isCurrentDidDisplay()) return;
        let didDisplayVisibleContentState = null;
        let didDisplayNativeLookupTargetCount = null;
        try {
            const doc = getPrimaryRendererContent(this.view?.renderer)?.doc ?? null;
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
        } catch {
        }
        if (!isCurrentDidDisplay()) return;
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
            if (!isCurrentDidDisplay()) return;
            // The final paginator settle has completed and the renderability probe
            // already found visible content. One animation-frame boundary is the
            // first opportunity for that final geometry to paint; a second frame
            // repeats the same full-document layout on large vertical sections.
            markLoadingPaintBoundary('after-frame-1-before-clear');
            this.setLoadingIndicator(false, 'didDisplay', { paintCommitted: true });
            markReaderRenderReady('didDisplay.loading-cleared');
            markLoadingPaintBoundary('after-clear');
        }
        if (!isCurrentDidDisplay()) return;
        this.hasReachedLoadingDidDisplayBoundary = true;
        try {
            const doc = getPrimaryRendererContent(this.view?.renderer)?.doc ?? null;
            if (isDocumentLike(doc) && !(Number.isFinite(didDisplayNativeLookupTargetCount) && didDisplayNativeLookupTargetCount > 0)) {
                this.#scheduleNativeLookupHitTargetRefreshSettle('didDisplay.render-ready', doc);
            }
        } catch (error) {
            console.error(error);
        }
        const hasRenderableContent = didDisplayVisibleContentState?.hasRenderableContent === true;
        if (hasRenderableContent) {
            globalThis.__manabiPostReaderDocStateEvent?.('didDisplay.loadingCleared');
            if (!isCurrentDidDisplay()) return;
        }
        if (hasRenderableContent) {
            this.#resolveInitialDisplaySettled('didDisplay.loading-cleared');
            this.#resolveDisplaySettledWaiters('didDisplay.loading-cleared');
        } else {
            this.#resolveDisplaySettledWaiters('didDisplay.no-visible-text');
        }
        if (!isCurrentDidDisplay()) return;
        if (hasRenderableContent) {
            try {
                globalThis.__manabiFinishEPUBLoadWatchdogs?.('didDisplay.loading-cleared');
            } catch (_error) {}
            if (!isCurrentDidDisplay()) return;
        }
        if (globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay === true) {
            this.navHUD?.setHideNavigationDueToScroll?.(true, 'mark-read.didDisplay.preserve-hidden', {
                stage: 'before-raf',
            });
            if (!isCurrentDidDisplay()) return;
            globalThis.__manabiPreserveHiddenNavigationThroughNextDisplay = false;
            globalThis.__manabiIgnoreNextIncomingRevealNavigationCount = 0;
        }
        if (this.navHUD?.hideNavigationDueToScroll) {
            this.navHUD.setHideNavigationDueToScroll(true, 'reader.didDisplay.reapply', {
                stage: 'before-raf',
            });
            if (!isCurrentDidDisplay()) return;
        }
        this.#applyHideNavigationDueToScrollToBookContent(this.navHUD?.hideNavigationDueToScroll === true, 'reader.didDisplay');
        this.#scheduleInitialPaginatorSettle('did-display');
    }
    #onLoad({
        detail: {
            doc,
            location = null,
            index = null,
        }
    }) {
        if (this.#closed) return
        const scope = this.#beginDocumentScope({ doc, location, index })
        if (!scope) return
        applyStoredChromeInsets('reader.documentLoad');
        applyLayoutSettingsToEbookDocument(doc);
        applyReaderPresentationStateToDocument(doc, globalThis.__manabiReaderPresentationState, 'document-load');
        applyNavigationHiddenStateToEbookDocument(doc, 'document-load');
        if (!isCacheWarmerDocument(doc)) {
            classifySingleMediaDocumentForInitialLayout(doc, 'document-load');
        }
        // Foliate fires document load before the paginator has rendered/columnized the
        // content. Running visible-segment sampling here forces layout, finds no
        // candidates, and cannot safely clear loading. The didDisplay path performs
        // the real visible-content pass after render.
        try {
            window.manabiForwardReaderFontToEbookDocuments?.('document-load', doc);
        } catch {
        }
        try {
            window.manabiApplyReaderThemeToEbookDocuments?.('document-load', doc);
        } catch (_error) {}
        try {
            window.manabiApplyReaderFontSizeToEbookDocuments?.('document-load', doc);
        } catch {
        }
        if (!isCacheWarmerDocument(doc)) {
            normalizeManabiSegmentWhitespace(doc);
        }
        if (doc?.fonts?.ready?.then) {
            doc.fonts.ready.then(() => {
                this.#refreshCommittedDocumentAfterFonts(scope, 'document.fonts-ready');
            }).catch(() => {
            });
        }
        this.#listenInDocumentScope(scope, doc, 'keydown', this.#handleKeydown.bind(this))
        if (
            doc
            && doc.__manabiMay20BlankTapLoggingOwner !== scope
            && !(MANABI_TEMP_DISABLE_EBOOK_NATIVE_LOOKUP_HIT_TARGETS && isEbookContentDocument(doc))
        ) {
            doc.__manabiMay20BlankTapLoggingOwner = scope;
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
            this.#listenInDocumentScope(scope, doc, 'touchstart', handleBlankPointerTouchStart, { passive: true, capture: true });
            this.#listenInDocumentScope(scope, doc, 'touchmove', handleBlankPointerTouchMove, { passive: true, capture: true });
            this.#listenInDocumentScope(scope, doc, 'touchend', handleBlankPointerTouchEnd, { passive: true, capture: true });
            this.#listenInDocumentScope(scope, doc, 'touchcancel', handleBlankPointerTouchEnd, { passive: true, capture: true });
            this.#listenInDocumentScope(scope, doc, 'mousedown', handleBlankPointerMouseDown, { passive: true, capture: true });
        }
        const restorePositionTrackingCleanup = installRestorePositionSaveUserInputTracking(
            doc,
            'reader-document'
        );
        if (typeof restorePositionTrackingCleanup === 'function') {
            scope.cleanups.add(restorePositionTrackingCleanup);
        }
    }
    #onDocumentCommitted({ detail = {} } = {}) {
        const scope = detail.doc ? this.#documentScopes.get(detail.doc) : null;
        if (!scope) return;
        this.#commitDocumentScope(scope, 'document-committed');
    }
    #onDocumentUnload({ detail = {} } = {}) {
        this.#releaseDocumentScope(
            detail.doc,
            detail.reason ?? 'document-unload'
        );
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
        if (this.#closed) return;
        let mainDocumentURL = (window.location != window.parent.location) ? document.referrer : document.location.href
        const content = getPrimaryRendererContent(this.view?.renderer);
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
        if (this.#closed) return;
        const relocateSequence = ++this.#relocateSequence;
        const lifecycleGeneration = this.#lifecycleGeneration;
        const isCurrentRelocate = () => this.#isLifecycleCurrent(lifecycleGeneration)
            && relocateSequence === this.#relocateSequence;
        const {
            fraction,
            location,
            cfi,
            reason
        } = detail
        const previousVisiblePageSegmentSnapshot = this.visiblePageSegmentSnapshot
            ?? this.lastInvalidatedVisiblePageSegmentSnapshot
            ?? null;
        this.#invalidateVisiblePageSegmentSnapshot('renderer.relocate');
        requestLookupCloseForPageMotion('renderer.relocate', {
            reason: reason ?? null,
            fraction: safeRound(fraction),
            currentLocation: location?.current ?? null,
            totalLocation: location?.total ?? null,
        });
        this.#publishCurrentContentPage(
            `relocate:${reason ?? 'unknown'}`
        );
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
            if (relocatedVisibleSegmentsResult) {
                if (relocatedVisibleSegmentsResult && hydrateStatuses) {
                    try {
                        const doc = getPrimaryRendererContent(this.view?.renderer)?.doc ?? null;
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
                const doc = getPrimaryRendererContent(this.view?.renderer)?.doc ?? null;
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
            reason === 'page'
            && document.body?.classList?.contains?.('loading') !== true;
        const relocateVisibleTargetGeneration = this.visiblePageCollectionGeneration;
        let postedPageTurnDisplayReady = false;
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
            // Foliate can deliver this relocate after didDisplay. In that order,
            // invalidation above cancels didDisplay's pending enrichment pass.
            // Re-arm the same deferred edge so loading/restore completion still
            // produces lookup targets and status paint after the first reveal.
            this.#scheduleNativeLookupHitTargetRefreshSettle('relocate.initial-render-ready');
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
        await this.navHUD?.handleRelocate(detail);
        if (!isCurrentRelocate()) return;
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
                const doc = getPrimaryRendererContent(this.view?.renderer)?.doc ?? null;
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
        await this.clearLoadingForRelocatedVisibleContent?.(reason ?? 'relocate', relocatedVisibleSegmentsResult);
        if (!isCurrentRelocate()) return;
        const primaryLabelDiagnostics = this.navHUD?.lastPrimaryLabelDiagnostics ?? null;
        const effectiveFractionDiagnostics = getAuthoritativeReaderFractionDiagnostics({
            navHUD: this.navHUD,
            detail,
            fallbackFraction: fraction,
        });
        const effectiveFraction = effectiveFractionDiagnostics.fraction;
        const progressFraction = ebookProgressFractionForRelocate({
            relocateFraction: fraction,
            authoritativeFraction: effectiveFraction,
        });
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
        if (!isCurrentRelocate()) return;
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
            if (shouldPersistRelocatePosition) {
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
                        const content = getPrimaryRendererContent(this.view?.renderer);
                        return content?.doc?.location?.href ?? content?.document?.location?.href ?? null;
                    })(),
                    expectedSectionIndex: sectionIndex,
                })
            }
        }

        await this.updateNavButtons({ relocateSequence });
        if (!isCurrentRelocate()) return;

        // Keep percent-jump input in sync with scroll
        const percentInput = document.getElementById('percent-jump-input');
        const percentButton = document.getElementById('percent-jump-button');
        if (percentInput && percentButton) {
            if (Number.isFinite(effectiveFraction)) {
                const pct = Math.round(effectiveFraction * 100);
                percentInput.value = pct;
                this.lastPercentValue = pct;
                percentButton.disabled = true;
            }
        }
    }

    async #onNavButtonClick(e) {
        const btn = e.currentTarget;
        const type = btn.dataset.buttonType;
        const renderer = this.view?.renderer;
        if (!renderer || this.#closed) return;

        markRestorePositionSaveUserInput(`nav-button.${type ?? 'unknown'}`);
        // The chapter controls are shared across Reader instances. Restore any
        // prior exact owner before snapshotting the UI for the next operation.
        finishOwnedElementOperation(btn);
        const icon = btn.querySelector('svg');
        const label = btn.querySelector('.button-label');
        const originalIcon = icon?.cloneNode(true) ?? null;
        const previousLabelVisibility = label?.style?.visibility ?? '';
        let spinner = null;
        if (label) label.style.visibility = 'hidden';
        if (icon) {
            spinner = document.createElement('div');
            spinner.className = 'ispinner nav-spinner';
            spinner.innerHTML = '<div class="ispinner-blade"></div>'.repeat(8);

            if (btn._spinnerAfterLabel) {
                icon.remove();
                const labels = btn.querySelectorAll('.button-label');
                let targetLabel = null;
                for (const candidate of labels) {
                    if (candidate.offsetParent !== null && getComputedStyle(candidate).display !== 'none') {
                        targetLabel = candidate;
                    }
                }
                if (targetLabel) {
                    targetLabel.after(spinner);
                } else {
                    btn.appendChild(spinner);
                }
            } else {
                icon.replaceWith(spinner);
            }
        }

        let fallbackTimer = null;
        let operation = null;
        const refreshAfterFinish = () => {
            const didFinish = operation?.finish?.() === true;
            if (didFinish) {
                void this.updateNavButtons().catch(error => console.error(error));
            }
            return didFinish;
        };
        operation = beginOwnedElementOperation(btn, () => {
            clearTimeout(fallbackTimer);
            fallbackTimer = null;
            this.#navButtonOperations.delete(operation);
            if (spinner?.isConnected) {
                if (originalIcon) {
                    spinner.replaceWith(originalIcon);
                } else {
                    spinner.remove();
                }
            }
            if (label) label.style.visibility = previousLabelVisibility;
        });
        this.#navButtonOperations.add(operation);
        fallbackTimer = setTimeout(refreshAfterFinish, navSpinnerMaximumMs);

        try {
            switch (type) {
            case 'prev':
                await renderer.prevSection();
                break;
            case 'next':
                await renderer.nextSection();
                break;
            default:
                break;
            }
        } catch (error) {
            console.error(error);
        } finally {
            refreshAfterFinish();
        }
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

window.setEbookViewerWritingDirection = (_writingDirection) => {
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
    const applyInitialRestore = restore => window.loadLastPosition?.({
        cfi: typeof restore?.cfi === 'string' ? restore.cfi : '',
        fractionalCompletion: restore?.fractionalCompletion,
    });
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
            const existingLoadToken = globalThis.manabiLoadEBookToken ?? null;
            const existingLoadPromise = globalThis.manabiLoadEBookPromise;
            const loadRestoreMailbox = globalThis.__manabiLoadRestoreMailbox ?? null;
            const willQueueInitialRestore = !!effectiveInitialRestore
                && loadRestoreMailbox instanceof PendingInitialRestoreMailbox
                && loadRestoreMailbox.matches({
                    loadToken: existingLoadToken,
                    url: requestedURL,
                })
                && loadRestoreMailbox.queue(effectiveInitialRestore);
            const willApplyRestoreAfterLoad = !!effectiveInitialRestore && !willQueueInitialRestore;
            globalThis.manabiLoadEBookLastState = willQueueInitialRestore
                ? 'duplicate-inflight-pending-restore'
                : (willApplyRestoreAfterLoad
                    ? 'duplicate-inflight-deferred-restore'
                    : 'duplicate-inflight');
            globalThis.manabiPendingLoadEBookArgs = null;
            globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.return', {
                path: globalThis.manabiLoadEBookLastState,
                existingStartedAgeMs,
                hasInitialRestore: !!effectiveInitialRestore,
                queuedInitialRestore: willQueueInitialRestore,
                deferredInitialRestore: willApplyRestoreAfterLoad,
                restoreKind: requestedRestoreKind,
                requestedFraction: requestedRestoreFraction != null ? safeRound(requestedRestoreFraction, 6) : null,
                hasRenderer: !!globalThis.reader?.view?.renderer,
            });
            if (!willApplyRestoreAfterLoad) {
                return existingLoadPromise;
            }
            return Promise.resolve(existingLoadPromise).then(() => {
                if (
                    globalThis.manabiLoadEBookToken !== existingLoadToken
                    || globalThis.manabiLoadEBookURL !== requestedURL
                    || !globalThis.reader?.view?.renderer
                ) {
                    return {
                        accepted: false,
                        superseded: true,
                        reason: 'load-superseded-before-deferred-restore',
                    };
                }
                return applyInitialRestore(effectiveInitialRestore);
            });
        }
        globalThis.manabiLoadEBookLastState = 'duplicate-inflight-stale-restart';
    }
    if (
        requestedURL.length > 0
        && globalThis.manabiLoadEBookURL === requestedURL
        && globalThis.manabiLoadEBookReady === true
        && globalThis.reader?.view?.renderer
    ) {
        const appliesRestore = !!effectiveInitialRestore;
        globalThis.manabiLoadEBookLastState = appliesRestore
            ? 'duplicate-ready-restore'
            : 'duplicate-ready';
        globalThis.manabiPendingLoadEBookArgs = null;
        globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.return', {
            path: globalThis.manabiLoadEBookLastState,
            hasInitialRestore: appliesRestore,
            initialRestoreHandled: !!globalThis.__manabiInitialRestoreHandled,
            hasRenderer: !!globalThis.reader?.view?.renderer,
            hasLoadedLastPosition: globalThis.reader?.hasLoadedLastPosition === true,
        });
        return appliesRestore ? applyInitialRestore(effectiveInitialRestore) : undefined;
    }
    const loadToken = (globalThis.manabiLoadEBookToken ?? 0) + 1;
    resetReaderTransientState(globalThis);
    lastPositionRestoreCoordinator.cancelCurrent(`loadEBook:${loadToken}`);
    globalThis.__manabiLoadRestoreMailbox?.close?.();
    const loadRestoreMailbox = new PendingInitialRestoreMailbox({
        loadToken,
        url: requestedURL,
    });
    globalThis.__manabiLoadRestoreMailbox = loadRestoreMailbox;
    globalThis.manabiLoadEBookToken = loadToken;
    globalThis.manabiLoadEBookURL = requestedURL;
    globalThis.manabiLoadEBookInFlight = true;
    globalThis.manabiLoadEBookStarted = true;
    globalThis.manabiLoadEBookStartedAt = Date.now();
    globalThis.manabiLoadEBookReady = false;
    globalThis.manabiLoadEBookLastState = 'start';
    globalThis.__manabiInitialRestoreResult = null;
    resetRestoreTransactionGlobals({ clearHandled: true });
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
    globalThis.__manabiFinishEPUBLoadWatchdogs = null;
    const replacedReader = globalThis.reader ?? null;
    try {
        if (typeof replacedReader?.close === 'function') {
            replacedReader.close('loadEBook.replace')
        } else {
            replacedReader?.view?.close?.()
            replacedReader?.view?.remove?.()
        }
    } catch (_error) {}
    let reader = new Reader()
    globalThis.reader = reader
    const isCurrentLoad = () => globalThis.manabiLoadEBookToken === loadToken
        && globalThis.__manabiLoadRestoreMailbox === loadRestoreMailbox
        && globalThis.reader === reader
        && reader.isClosed !== true;
    reader.setLoadingIndicator(true, 'loadEBook.start');

    const ebookSource = typeof url === 'string' && url.length > 0 && url.startsWith('ebook://')
        ? makeNativeSource(url)
        : null

    if (url) {
        globalThis.manabiLoadEBookLastState = 'source-start';
        const sourcePromise = ebookSource
            ? Promise.resolve(ebookSource).then((source) => {
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
                    return makeFileSource(new File([blob], new URL(url).pathname))
                })

        const openPromise = sourcePromise
        .then(async (source) => {
            if (!isCurrentLoad()) return;
            globalThis.manabiLoadEBookLastState = 'source-ready';
            globalThis.manabiPendingLoadEBookArgs = null;
            if (layoutMode) {
                window.initialLayoutMode = layoutMode
                globalThis.__manabiEbookViewerLayoutMode = layoutMode
            }
            const pendingInitialRestoreAtOpen = loadRestoreMailbox.hasPending;
            const initialRestoreForOpen = effectiveInitialRestore;
            globalThis.manabiLoadEBookLastState = 'reader-open-dispatch';
            globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.readerOpen.dispatch', {
                loadToken,
                hasInitialRestore: !!initialRestoreForOpen,
                hasPendingInitialRestore: pendingInitialRestoreAtOpen,
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
            if (!isCurrentLoad()) {
                reader.close('loadEBook.superseded-after-open')
                return;
            }
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
                finalizeInitialRestoreHandledWithoutNativeRestore('loadEBook.initialRestoreHandled', reader);
            }
            const pendingInitialRestoreAfterOpen = loadRestoreMailbox.hasPending;
            const shouldDeferReaderOpenLoadingClear =
                globalThis.__manabiInitialRestoreRenderReadyGate?.active === true
                && !globalThis.__manabiInitialRestoreHandled
                && (!!initialRestoreForOpen || pendingInitialRestoreAfterOpen);
            if (!shouldDeferReaderOpenLoadingClear) {
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
            let appliedPendingInitialRestore = false;
            let pendingRestoreSucceeded = false;
            let pendingRestoreSuperseded = false;
            while (isCurrentLoad()) {
                const pendingInitialRestore = loadRestoreMailbox.take();
                if (!pendingInitialRestore) break;
                appliedPendingInitialRestore = true;
                const pendingFraction = coerceRestoreFraction(pendingInitialRestore?.fractionalCompletion);
                globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.pendingRestore.apply', {
                    loadToken,
                    cfiLength: typeof pendingInitialRestore?.cfi === 'string' ? pendingInitialRestore.cfi.length : 0,
                    requestedFraction: pendingFraction != null ? safeRound(pendingFraction, 6) : null,
                    initialRestoreHandledBeforeApply: !!globalThis.__manabiInitialRestoreHandled,
                    hasLoadedLastPositionBeforeApply: reader?.hasLoadedLastPosition === true,
                });
                try {
                    const pendingRestoreResult = await applyInitialRestore(pendingInitialRestore);
                    if (!isCurrentLoad()) return;
                    pendingRestoreSuperseded = pendingRestoreResult?.superseded === true;
                    pendingRestoreSucceeded = !pendingRestoreSuperseded
                        && reader?.hasLoadedLastPosition === true
                        && !!globalThis.__manabiInitialRestoreHandled;
                } catch {
                    pendingRestoreSucceeded = false;
                }
                globalThis.__manabiRestoreDebugLog?.('ebook.loadEBook.pendingRestore.finish', {
                    loadToken,
                    restored: pendingRestoreSucceeded,
                    initialRestoreHandledAfterApply: !!globalThis.__manabiInitialRestoreHandled,
                    hasLoadedLastPositionAfterApply: reader?.hasLoadedLastPosition === true,
                    currentFraction: typeof reader?.view?.lastLocation?.fraction === 'number'
                        ? safeRound(reader.view.lastLocation.fraction, 6)
                        : null,
                });
            }
            const activeRestoreOwner = lastPositionRestoreCoordinator.current;
            const newerRestoreOwnsReader = activeRestoreOwner?.context?.reader === reader
                && activeRestoreOwner?.context?.loadToken === loadToken;
            if (!pendingRestoreSuperseded && !newerRestoreOwnsReader) {
                if (
                    appliedPendingInitialRestore
                    && pendingRestoreSucceeded
                    && shouldDeferReaderOpenLoadingClear
                ) {
                    const settled = reader.settleInitialDisplayFromVisibleContent?.('loadEBook.pendingRestoreAfterApply');
                    finishInitialRestoreRenderReadyGateWithTerminalResult('loadEBook.pendingRestoreAfterApply');
                    reader.finishRestoreLoading(settled, 'loadEBook.pendingRestoreAfterApply');
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
                    reader.completeLastPositionLoadAttempt('loadEBook.initialRestoreNotHandledAfterOpen');
                    reader.finishRestoreLoading(settled, 'loadEBook.initialRestoreNotHandledAfterOpen');
                } else if (
                    shouldDeferReaderOpenLoadingClear
                    && !globalThis.__manabiInitialRestoreHandled
                    && globalThis.__manabiInitialRestoreRenderReadyGate?.active === true
                ) {
                    const settled = reader.settleInitialDisplayFromVisibleContent?.('loadEBook.initialRestoreDeferredTerminal');
                    finishInitialRestoreRenderReadyGateWithTerminalResult('loadEBook.initialRestoreDeferredTerminal');
                    reader.hasLoadedLastPosition = false;
                    reader.completeLastPositionLoadAttempt('loadEBook.initialRestoreDeferredTerminal');
                    reader.finishRestoreLoading(settled, 'loadEBook.initialRestoreDeferredTerminal');
                }
            }
        })
        .then(async () => {
            if (!isCurrentLoad()) return;
            const terminalPendingInitialRestore = loadRestoreMailbox.closeAndTake();
            if (terminalPendingInitialRestore) {
                await applyInitialRestore(terminalPendingInitialRestore);
                if (!isCurrentLoad()) return;
            }
            const publishedReady = await commitAfterMatchingRestoreTransactionsSettle({
                coordinator: lastPositionRestoreCoordinator,
                matches: owner => owner?.context?.reader === reader
                    && owner?.context?.loadToken === loadToken,
                isCurrent: isCurrentLoad,
                commit: () => {
                    if (!isCurrentLoad()) return false;
                    globalThis.reader = reader;
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
                    });
                    return true;
                },
            });
            if (!publishedReady) return;
        })
        .catch((error) => {
            if (!isCurrentLoad()) {
                reader.close('loadEBook.superseded-error');
                return;
            }
            finishInitialForegroundCriticalSection('loadEBook.error');
            globalThis.manabiLoadEBookReady = false;
            globalThis.manabiLoadEBookLastState = `open-error:${error?.message || String(error)}`;
            reader.setLoadingIndicator(false, 'loadEBook.error', { terminal: true });
            reader.close('loadEBook.error');
            if (globalThis.reader === reader) globalThis.reader = null;
            throw error;
        })
        .finally(() => {
            loadRestoreMailbox.close();
            if (globalThis.__manabiLoadRestoreMailbox === loadRestoreMailbox) {
                globalThis.__manabiLoadRestoreMailbox = null;
            }
            if (globalThis.manabiLoadEBookToken !== loadToken) return;
            globalThis.manabiLoadEBookInFlight = false;
            globalThis.manabiLoadEBookPromise = null;
        })
        globalThis.manabiLoadEBookPromise = openPromise;
        return openPromise;
    } else {
        loadRestoreMailbox.close();
        if (globalThis.__manabiLoadRestoreMailbox === loadRestoreMailbox) {
            globalThis.__manabiLoadRestoreMailbox = null;
        }
        finishInitialForegroundCriticalSection('loadEBook.no-url');
        reader.setLoadingIndicator(false, 'loadEBook.no-url', { terminal: true });
        reader.close('loadEBook.no-url');
        if (globalThis.reader === reader) globalThis.reader = null;
        globalThis.manabiLoadEBookReady = false;
        globalThis.manabiLoadEBookLastState = 'no-url';
        globalThis.manabiPendingLoadEBookArgs = null;
        globalThis.manabiLoadEBookInFlight = false;
        globalThis.manabiLoadEBookPromise = null;
    }
    //.catch(e => console.error(e))
}

const markRestorePositionSaveUserInput = (_source = 'unknown') => {
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
        return () => {};
    }
    const registrations = [];
    for (const eventName of ['pointerdown', 'touchstart', 'wheel', 'keydown', 'click']) {
        const listener = (event) => {
            markRestorePositionSaveUserInput(`${source}.${event?.type ?? eventName}`);
        };
        const options = {
            capture: true,
            passive: true,
        };
        target.addEventListener(eventName, listener, options);
        registrations.push([eventName, listener, options]);
    }
    return () => {
        for (const [eventName, listener, options] of registrations) {
            target.removeEventListener?.(eventName, listener, options);
        }
    };
};

const finalizeInitialRestoreHandledWithoutNativeRestore = (
    reason = 'loadEBook.initialRestoreHandled',
    reader = globalThis.reader
) => {
    const handled = globalThis.__manabiInitialRestoreHandled ?? null;
    if (!handled || !reader?.view?.renderer || reader.isClosed === true) {
        return false;
    }
    ensureRestorePositionSaveUserInputTracking();
    globalThis.__manabiSuppressNextRestoreRelocateSave = true;
    globalThis.__manabiRequireUserInputBeforePositionSave = true;
    globalThis.__manabiRestoreInProgress = false;
    reader.completeLastPositionLoad(reason);
    const visibleSettleResult = reader.settleInitialDisplayFromVisibleContent?.(`${reason}.visibleContent`);
    if (visibleSettleResult?.settled === true) {
        clearInitialRestoreRenderReadyGate(reason);
        markReaderRenderReady(reason);
    }
    reader.refreshNativeMarkReadState?.(`${reason}.markRead`);
    globalThis.__manabiRestoreDebugLog?.('ebook.initialRestore.finalized', {
        reason,
        sectionIndex: handled.sectionIndex ?? null,
        localSectionIndex: handled.localSectionIndex ?? null,
        rendererTotal: handled.rendererTotal ?? null,
        fractionalCompletion: Number.isFinite(handled.fractionalCompletion) ? safeRound(handled.fractionalCompletion, 6) : null,
        cfiLength: typeof handled.cfi === 'string' ? handled.cfi.length : 0,
        hasLoadedLastPosition: reader?.hasLoadedLastPosition === true,
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
    const restoreReader = globalThis.reader ?? null;
    const restoreLoadToken = globalThis.manabiLoadEBookToken ?? null;
    if (!restoreReader || restoreReader.isClosed === true) {
        return {
            accepted: false,
            superseded: true,
            reason: 'missing-reader',
        };
    }
    const restoreOwner = lastPositionRestoreCoordinator.begin({
        reader: restoreReader,
        loadToken: restoreLoadToken,
    });
    const isCurrentRestore = () => lastPositionRestoreCoordinator.isCurrent(restoreOwner)
        && globalThis.reader === restoreReader
        && globalThis.manabiLoadEBookToken === restoreLoadToken
        && restoreReader.isClosed !== true;
    const assertCurrentRestore = (reason = 'reader-or-load-superseded') => {
        if (isCurrentRestore()) return;
        lastPositionRestoreCoordinator.cancel(restoreOwner, reason);
        throw makeRestoreTransactionSupersededError(
            restoreOwner.cancelReason ?? reason
        );
    };
    const waitForOwnedRestore = async (operation) => {
        assertCurrentRestore();
        const value = await lastPositionRestoreCoordinator.wait(
            restoreOwner,
            operation
        );
        assertCurrentRestore();
        return value;
    };
    const previouslyHandledInitialRestore = globalThis.__manabiInitialRestoreHandled ?? null;
    let restoreLocatorKind = 'unknown';
    let shouldKeepRestoreSaveGuard = false;
    const captureRestoreState = (stage, _extra = {}) => {
        assertCurrentRestore(`capture-state:${stage}`);
        const detail = restoreReader?.view?.lastLocation ?? null;
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

    try {
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
            const navigationResult = await waitForOwnedRestore(
                () => runAcceptedRestoreNavigation(
                    () => runWithNavigationIntent(intent, operation, { timeoutMs })
                )
            );
            if (navigationResult.ok) {
                return {
                    ok: true,
                    result: navigationResult.value,
                };
            }
            if (throwOnError) {
                throw navigationResult.error;
            }
            return {
                ok: false,
                error: navigationResult.error,
            };
        };
        const waitForFrames = async (count = 2) => {
            for (let index = 0; index < count; index += 1) {
                await waitForOwnedRestore(
                    () => new Promise((resolve) => requestAnimationFrame(() => resolve()))
                );
            }
        };
        const waitForPaintAfterNavigation = async () => {
            await waitForFrames(2);
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
            const visibleSettleResult = typeof restoreReader?.settleInitialDisplayFromVisibleContent === 'function'
                ? restoreReader.settleInitialDisplayFromVisibleContent(`loadLastPosition.${reason}`)
                : null;
            assertCurrentRestore(`visible-settle:${reason}`);
            let waitedState = captureRestoreState(stage, {
                waitedForDisplay: false,
                visibleContentSettled: visibleSettleResult?.settled === true,
            });
            let displaySettledResult = null;
            if (
                (!restoreStateHasUsableLocation(waitedState)
                    || (requireFractionSatisfied && !restoreStateFractionSatisfied(waitedState)))
                && typeof restoreReader?.waitForNextDisplaySettled === 'function'
            ) {
                displaySettledResult = await waitForOwnedRestore(
                    () => restoreReader.waitForNextDisplaySettled(
                        `loadLastPosition.${reason}`,
                        { timeoutMs }
                    )
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
        restoreLocatorKind = syntheticRestoreLocator
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
            hasLoadedLastPosition: restoreReader?.hasLoadedLastPosition === true,
            restoreInProgress: globalThis.__manabiRestoreInProgress === true,
        });
        const releaseDispatchedNavigation = (reason, {
            markReadyReason = null,
        } = {}) => {
            assertCurrentRestore(`release-navigation:${reason}`);
            globalThis.__manabiRestoreInProgress = false;
            restoreReader.completeLastPositionLoad(reason);
            globalThis.__manabiSuppressNextRestoreRelocateSave = true;
            globalThis.__manabiRequireUserInputBeforePositionSave = true;
            shouldKeepRestoreSaveGuard = true;
            const visibleSettleResult = markReadyReason
                ? restoreReader?.settleInitialDisplayFromVisibleContent?.(`${markReadyReason}.visibleContent`)
                : null;
            assertCurrentRestore(`release-navigation-visible-settle:${reason}`);
            if (markReadyReason && visibleSettleResult?.settled === true) {
                clearInitialRestoreRenderReadyGate(markReadyReason);
                markReaderRenderReady(markReadyReason);
            }
            restoreReader?.setLoadingIndicator?.(false, reason);
        };
        const reconcileRestoreFractionIfNeeded = async (restoreState, reason, stageOnReconcile) => {
            assertCurrentRestore(`reconcile:${reason}`);
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
            const rendererPageCurrent = restoreReader?.navHUD?.rendererPageSnapshot?.current ?? null;
            const rendererPageTotal = restoreReader?.navHUD?.rendererPageSnapshot?.total ?? null;
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
            }, () => restoreReader.view.goToFraction(fractionalCompletion), {
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
            && finalizeInitialRestoreHandledWithoutNativeRestore('loadLastPosition.initialRestoreStaleNativeCall', restoreReader)
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
            restoreReader.completeLastPositionLoad('initial-restore-already-handled');
            globalThis.__manabiSuppressNextRestoreRelocateSave = true;
            globalThis.__manabiRequireUserInputBeforePositionSave = true;
            shouldKeepRestoreSaveGuard = true;
            const visibleSettleResult = restoreReader.settleInitialDisplayFromVisibleContent?.('loadLastPosition.initialRestoreAlreadyHandled.visibleContent');
            if (visibleSettleResult?.settled === true) {
                clearInitialRestoreRenderReadyGate('loadLastPosition.initialRestoreAlreadyHandled');
                markReaderRenderReady('loadLastPosition.initialRestoreAlreadyHandled');
            }
            restoreReader?.maybeFlashInitialForwardSideNavChevron?.(initialState);
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
            }, () => restoreReader.view.renderer.goTo?.({
                index: syntheticRestoreLocator.sectionIndex,
                localPage: syntheticRestoreLocator.localSectionIndex,
            }), {
                throwOnError: false,
            });
            if (navigationResult?.ok !== true) {
                throw navigationResult?.error ?? new Error('Synthetic restore navigation failed');
            }
            await waitForPaintAfterNavigation();
            const visibleSettleResult = restoreReader.settleInitialDisplayFromVisibleContent?.('loadLastPosition.syntheticNavigationSettled');
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
                    return restoreReader.view.goToFraction(fractionalCompletion);
                }
                return restoreReader.view.renderer.goTo?.({
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
            }, async () => (await restoreReader.view.goTo(cfi)) != null, {
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
                }, () => restoreReader.view.goToFraction(fractionalCompletion));
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
            await waitForOwnedRestore(
                () => restoreReader?.displayInitialSection?.('loadLastPosition.noRestoreTarget')
            );
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
        assertCurrentRestore('publish-done-state');
        restoreReader.hasLoadedLastPosition = !hasExplicitRestoreTarget || doneHasUsableLocation;
        const doneVisibleSettleResult = restoreReader.settleInitialDisplayFromVisibleContent?.('loadLastPosition.done.visibleContent');
        assertCurrentRestore('publish-done-visible-settle');
        if (
            restoreReader.hasLoadedLastPosition
            && doneVisibleSettleResult?.settled === true
            && (!syntheticRestoreLocator || syntheticDisplaySettledForRestore)
        ) {
            clearInitialRestoreRenderReadyGate('loadLastPosition.done');
            markReaderRenderReady('loadLastPosition.done');
        }
        if (restoreReader.hasLoadedLastPosition) {
            restoreReader.refreshNativeMarkReadState?.('load-last-position-done');
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
        restoreReader?.maybeFlashInitialForwardSideNavChevron?.(doneState);
        globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.done', {
            restoreLocatorKind,
            requestedFraction: Number.isFinite(fractionalCompletion) ? safeRound(fractionalCompletion, 6) : null,
            currentFraction: typeof doneState.currentFraction === 'number' ? safeRound(doneState.currentFraction, 6) : null,
            currentSectionIndex: doneState.sectionIndex ?? null,
            locationCurrent: doneState.locationCurrent ?? null,
            locationTotal: doneState.locationTotal ?? null,
            hasLoadedLastPosition: restoreReader?.hasLoadedLastPosition === true,
            locationUsable: doneHasUsableLocation,
            fractionSatisfied: doneFractionSatisfied,
            updatedInitialRestoreHandled: restoredExplicitPosition,
            suppressNextSave: globalThis.__manabiSuppressNextRestoreRelocateSave === true,
            requireUserInputBeforeSave: globalThis.__manabiRequireUserInputBeforePositionSave === true,
        });
    } catch (error) {
        if (isRestoreTransactionSupersededError(error) || !isCurrentRestore()) {
            return {
                accepted: false,
                superseded: true,
                reason: error?.reason ?? restoreOwner.cancelReason ?? 'superseded',
            };
        }
        console.error(error);
        restoreReader.hasLoadedLastPosition = false;
        restoreReader.completeLastPositionLoadAttempt('loadLastPosition.failed');
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
        restoreReader?.setLoadingIndicator?.(false, 'loadLastPosition.failed', { terminal: true });
        throw error;
    } finally {
        const ownsFinalization = isCurrentRestore();
        if (ownsFinalization) {
            globalThis.__manabiRestoreInProgress = false;
            if (!shouldKeepRestoreSaveGuard) {
                globalThis.__manabiSuppressNextRestoreRelocateSave = false;
            }
            globalThis.__manabiRequireUserInputBeforePositionSave = true;
            if (isCurrentRestore() && restoreReader?.hasLoadedLastPosition === true) {
                restoreReader.completeLastPositionLoad('load-last-position-finally');
            }
            if (isCurrentRestore()) {
                restoreReader?.setLoadingIndicator?.(false, 'loadLastPosition.finally');
            }
            if (isCurrentRestore() && restoreReader?.hasLoadedLastPosition === true) {
                restoreReader.refreshNativeMarkReadState?.('load-last-position-finally');
            }
            if (isCurrentRestore()) {
                globalThis.__manabiRestoreDebugLog?.('ebook.loadLastPosition.finally', {
                    restoreLocatorKind,
                    hasLoadedLastPosition: restoreReader?.hasLoadedLastPosition === true,
                    restoreInProgress: globalThis.__manabiRestoreInProgress === true,
                    suppressNextSave: globalThis.__manabiSuppressNextRestoreRelocateSave === true,
                    requireUserInputBeforeSave: globalThis.__manabiRequireUserInputBeforePositionSave === true,
                });
            }
            lastPositionRestoreCoordinator.finish(restoreOwner);
        }
    }
}

window.refreshBookReadingProgress = async (articleReadingProgress) => {
    if (!globalThis.reader) {
        return;
    }
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
        pageTurnRequested: false,
        moved: false,
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
    return await globalThis.reader?.goToPageNumber?.(pageNumber, 'window.manabiGoToReaderPage');
}

window.manabiScheduleReaderLocationGoTo = (locationNumber) => {
    markRestorePositionSaveUserInput('bridge.scheduleReaderLocationGoTo');
    globalThis.reader?.scheduleGoToPageNumber?.(locationNumber);
}

window.manabiGoToReaderLocation = async (locationNumber) => {
    markRestorePositionSaveUserInput('bridge.goToReaderLocation');
    return await globalThis.reader?.goToLocationNumber?.(locationNumber, 'window.manabiGoToReaderLocation');
}

window.manabiGoToReaderPercent = async (percent) => {
    markRestorePositionSaveUserInput('bridge.goToReaderPercent');
    return await globalThis.reader?.goToPercent?.(percent, 'window.manabiGoToReaderPercent');
}

window.manabiGoToReaderHref = async (href) => {
    markRestorePositionSaveUserInput('bridge.goToReaderHref');
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
        const explicitRelocateOwnership = navHUD?.requestExplicitRelocateHistoryMutation?.(
            'scrub-release'
        );
        try {
            const accepted = await runWithNavigationIntent({
                source: 'scrub-release',
                target: 'view.goToFraction',
                fraction: clampedFraction,
            }, () => view.goToFraction(clampedFraction, {
                relocationID: explicitRelocateOwnership?.relocationID ?? null,
            }));
            if (accepted !== true) {
                navHUD?.cancelExplicitRelocateHistoryMutation?.(explicitRelocateOwnership);
            }
            finalizeScrubSession();
        } catch (error) {
            navHUD?.cancelExplicitRelocateHistoryMutation?.(explicitRelocateOwnership);
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
    const isCurrentRenderer = () => globalThis.reader === reader
        && reader?.isClosed !== true
        && reader?.view?.renderer === renderer;
    return await advanceCurrentRendererSection({
        renderer,
        getCurrentIndex: () => getPrimaryRendererContentIndex(renderer),
        isCurrent: isCurrentRenderer,
    });
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
