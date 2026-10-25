import {
    compactEbookSegmentMetadataPayloadIsCurrent,
    compactEbookSegmentSchemaVersionsAreCompatible,
    compactEbookSegmentSidecarVersion,
    expandCompactEbookSegmentResolution,
    expandCompactEbookSegmentIDToken,
} from './ebook-segment-identity.js'

export const emptySegmentMetadataBootstrap = () => ({
    byID: new Map(),
    idsByEntryID: new Map(),
    hasEntryIDs: false,
    segments: [],
    aggregates: null,
    sentenceArchive: new Map(),
})

const stableSegmentID = (sentenceID, segmentHash) => (
    typeof sentenceID === 'string' && sentenceID.length > 0
    && typeof segmentHash === 'string' && segmentHash.length > 0
        ? `${sentenceID}-${segmentHash}`
        : null
)

export const createEbookSegmentMetadataBootstrap = ({
    nativeSchemaVersion = globalThis.manabi_compactSegmentSidecarSchemaVersion,
} = {}) => {
    const manabiSegmentSidecarParserVersion = compactEbookSegmentSidecarVersion
    const manabiSegmentSidecarNativeVersion = Number.isSafeInteger(
        nativeSchemaVersion
    )
        ? nativeSchemaVersion
        : null
    const manabiSegmentSidecarSchemaIsCompatible = compactEbookSegmentSchemaVersionsAreCompatible(
        manabiSegmentSidecarNativeVersion
    )
    const manabiCanParseCompactSegmentSidecar = (payload) => (
        manabiSegmentSidecarSchemaIsCompatible
        && compactEbookSegmentMetadataPayloadIsCurrent(payload)
    )
    const schemaDiagnostics = Object.freeze({
        parserVersion: manabiSegmentSidecarParserVersion,
        nativeVersion: manabiSegmentSidecarNativeVersion,
        nativeSchemaIsCompatible: manabiSegmentSidecarSchemaIsCompatible,
        acceptsPayload: manabiCanParseCompactSegmentSidecar,
    })

    const manabiSidecarTableValue = (table, index, fallback = null) => (
        Number.isInteger(index) && Array.isArray(table) && index >= 0 && index < table.length
            ? table[index]
            : fallback
    )

    const manabiSidecarTableArray = (tables, shortKey) => (
        Array.isArray(tables?.[shortKey])
            ? tables[shortKey]
            : []
    )

    const manabiExpandSegmentIDToken = expandCompactEbookSegmentIDToken

    const manabiExpandCompactSegmentMetadata = (segment, tables) => {
        const segmentHash = manabiSidecarTableValue(tables.h, segment?.[1], null)
        const sentenceID = manabiSidecarTableValue(tables.sid, segment?.[9], null)
        const paragraphID = manabiSidecarTableValue(tables.pid, segment?.[10], null)
        const jmdictEntryIDs = manabiSidecarTableValue(tables.j, segment?.[2], [])
        const jmnedictEntryIDs = manabiSidecarTableValue(tables.n, segment?.[3], [])
        const resolution = expandCompactEbookSegmentResolution(
            manabiSidecarTableValue(tables.res, segment?.[11], null),
            jmdictEntryIDs,
            jmnedictEntryIDs
        )
        return {
            i: manabiExpandSegmentIDToken(segment?.[0]),
            h: segmentHash,
            sid: stableSegmentID(sentenceID, segmentHash),
            sentenceID,
            paragraphID,
            pid: paragraphID,
            j: jmdictEntryIDs,
            n: jmnedictEntryIDs,
            s: manabiSidecarTableValue(tables.s, segment?.[4], null),
            ns: manabiSidecarTableValue(tables.ns, segment?.[5], null),
            p: manabiSidecarTableValue(tables.p, segment?.[6], null),
            l: segment?.[7],
            x: manabiSidecarTableValue(tables.x, segment?.[8], null),
            scopeText: manabiSidecarTableValue(tables.x, segment?.[12], null),
            paragraphScopeText: manabiSidecarTableValue(tables.x, segment?.[13], null),
            selectedLexicon: resolution?.selectedLexicon ?? null,
            selectedEntryID: resolution?.selectedEntryID ?? null,
            canonicalSearchString: resolution?.canonicalSearchString ?? null,
            requiresCommittedDictionarySelection: true,
        }
    }

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
        res: manabiSidecarTableArray(payload.t, 'res'),
    })

    class ManabiLazySegmentMetadataMap extends Map {
        constructor(payload) {
            super()
            this.compactSegments = []
            this.tables = null
            this.indexedSegmentCount = 0
            this.materializedSegmentCount = 0
            this.stableAliasesIndexed = false
            if (!manabiCanParseCompactSegmentSidecar(payload)) {
                return
            }
            this.compactSegments = payload.s
            this.tables = manabiCompactSegmentMetadataTables(payload)
            for (let tupleIndex = 0; tupleIndex < payload.s.length; tupleIndex += 1) {
                const compactSegment = payload.s[tupleIndex]
                const elementID = manabiExpandSegmentIDToken(compactSegment?.[0])
                if (!elementID) continue
                const reference = tupleIndex + 1
                super.set(elementID, reference)
                this.indexedSegmentCount += 1
            }
        }

        ensureStableAliasesIndexed() {
            if (this.stableAliasesIndexed || !this.tables) return
            this.stableAliasesIndexed = true
            for (let tupleIndex = 0; tupleIndex < this.compactSegments.length; tupleIndex += 1) {
                const compactSegment = this.compactSegments[tupleIndex]
                const segmentHash = manabiSidecarTableValue(this.tables.h, compactSegment?.[1], null)
                const sentenceID = manabiSidecarTableValue(this.tables.sid, compactSegment?.[9], null)
                const stableID = stableSegmentID(sentenceID, segmentHash)
                if (stableID) {
                    const runtimeID = manabiExpandSegmentIDToken(compactSegment?.[0])
                    const runtimeMetadata = super.get(runtimeID)
                    // Keep prior lazy materialization while preserving tuple-order alias winners.
                    const reference = runtimeMetadata !== null
                        && typeof runtimeMetadata === 'object'
                        && runtimeMetadata.i === runtimeID
                        ? runtimeMetadata
                        : tupleIndex + 1
                    super.set(stableID, reference)
                }
            }
        }

        get(identifier) {
            let value = super.get(identifier)
            if (value === undefined) {
                this.ensureStableAliasesIndexed()
                value = super.get(identifier)
            }
            if (!Number.isInteger(value)) return value
            const compactSegment = this.compactSegments[value - 1]
            if (!compactSegment || !this.tables) return undefined
            const metadata = manabiExpandCompactSegmentMetadata(compactSegment, this.tables)
            // Runtime reads cannot claim an unindexed stable alias or overwrite
            // a different tuple's stable winner.
            for (const alias of manabiSegmentMetadataAliases(metadata)) {
                if (alias === metadata.i || super.get(alias) === value) {
                    super.set(alias, metadata)
                }
            }
            this.materializedSegmentCount += 1
            return metadata
        }

        has(identifier) {
            return this.get(identifier) !== undefined
        }
    }

    class ManabiLazySegmentScopeMap extends Map {
        constructor(compactSegments, scopeTable, scopeTupleIndex) {
            super()
            this.compactSegments = compactSegments
            this.scopeTable = scopeTable
            this.scopeTupleIndex = scopeTupleIndex
            this.isIndexed = false
        }

        ensureIndexed() {
            if (this.isIndexed) return
            // Sentence and paragraph pickers are user-driven. Build their deterministic sidecar
            // indexes on first use instead of allocating arrays for the whole section before paint.
            this.isIndexed = true
            for (const compactSegment of this.compactSegments) {
                const scopeID = manabiSidecarTableValue(
                    this.scopeTable,
                    compactSegment?.[this.scopeTupleIndex],
                    null
                )
                const elementID = manabiExpandSegmentIDToken(compactSegment?.[0])
                if (typeof scopeID !== 'string' || scopeID.length === 0 || !elementID) continue
                const existingSegmentIDs = super.get(scopeID)
                if (existingSegmentIDs) {
                    existingSegmentIDs.push(elementID)
                } else {
                    super.set(scopeID, [elementID])
                }
            }
        }

        get(identifier) {
            this.ensureIndexed()
            return super.get(identifier)
        }
    }

    const manabiSegmentMetadataAliases = (segment) => {
        const aliases = []
        const add = (identifier) => {
            if (typeof identifier !== 'string' || identifier.length === 0) return
            if (!aliases.includes(identifier)) aliases.push(identifier)
        }
        add(segment?.i)
        add(segment?.sid)
        return aliases
    }

    const manabiSegmentMetadataSidecarSnapshot = (doc) => {
        if (!doc) return { sidecars: [], sidecarTexts: [], sidecarPayloads: [], sidecarSignature: 'none' }
        const canonicalSidecar = doc.getElementById?.('mnb-segment-metadata') ?? null
        // Processed EPUB sections have one canonical Swift-emitted sidecar. Keep this
        // bootstrap O(1); the general reader script owns dynamic multi-sidecar content.
        const sidecars = canonicalSidecar ? [canonicalSidecar] : []
        const externalEntry = canonicalSidecar ? null : (doc.manabiExternalSegmentSidecar ?? null)
        const cachedSnapshot = doc.__manabiFoliateSegmentMetadataSidecarSnapshot
        if (cachedSnapshot?.sidecars?.length === sidecars.length
            && sidecars.every((sidecar, index) => cachedSnapshot.sidecars[index] === sidecar)
            && cachedSnapshot.externalEntry === externalEntry) {
            return cachedSnapshot
        }
        const sidecarTexts = sidecars.length > 0
            ? sidecars.map(sidecar => sidecar.textContent || '')
            : (externalEntry?.payload ? [''] : [])
        // The Swift-produced sidecar node is immutable for the lifetime of its EPUB document, and
        // cache reuse above is already guarded by node identity. Use an identity generation instead
        // of hashing its large JSON text on the first visible load.
        if (canonicalSidecar) {
            doc.__manabiFoliateSegmentMetadataSidecarGeneration =
                (doc.__manabiFoliateSegmentMetadataSidecarGeneration || 0) + 1
        }
        const sidecarSignature = externalEntry?.signature
            ? `external:${externalEntry.signature}`
            : (canonicalSidecar
                ? `canonical:${doc.__manabiFoliateSegmentMetadataSidecarGeneration}`
                : 'none')
        const snapshot = {
            sidecars,
            sidecarTexts,
            sidecarPayloads: externalEntry?.payload ? [externalEntry.payload] : [],
            sidecarSignature,
            externalEntry,
        }
        doc.__manabiFoliateSegmentMetadataSidecarSnapshot = snapshot
        return snapshot
    }

    const manabiSidecarNumberArray = (value) => Array.isArray(value)
        ? value.filter(item => typeof item === 'number' && Number.isFinite(item))
        : []

    const manabiMaxExampleSentenceCodePointCount = 7000
    const manabiHighSurrogateMinimum = 0xD800
    const manabiHighSurrogateMaximum = 0xDBFF
    const manabiLowSurrogateMinimum = 0xDC00
    const manabiLowSurrogateMaximum = 0xDFFF
    const manabiAmpersandCodeUnit = 0x26
    const manabiApostropheCodeUnit = 0x27
    const manabiQuotationMarkCodeUnit = 0x22
    const manabiLessThanCodeUnit = 0x3C
    const manabiGreaterThanCodeUnit = 0x3E

    const manabiEscapedExampleSentenceHTML = (text) => {
        const escapedParts = []
        let chunkStart = 0
        let index = 0
        let codePointCount = 0
        while (index < text.length && codePointCount < manabiMaxExampleSentenceCodePointCount) {
            const codeUnit = text.charCodeAt(index)
            let replacement = null
            switch (codeUnit) {
            case manabiAmpersandCodeUnit:
                replacement = '&amp;'
                break
            case manabiLessThanCodeUnit:
                replacement = '&lt;'
                break
            case manabiGreaterThanCodeUnit:
                replacement = '&gt;'
                break
            case manabiQuotationMarkCodeUnit:
                replacement = '&quot;'
                break
            case manabiApostropheCodeUnit:
                replacement = '&#39;'
                break
            default:
                break
            }
            if (replacement !== null) {
                if (chunkStart < index) {
                    escapedParts.push(text.slice(chunkStart, index))
                }
                escapedParts.push(replacement)
                chunkStart = index + 1
            }
            let codeUnitLength = 1
            if (
                codeUnit >= manabiHighSurrogateMinimum
                && codeUnit <= manabiHighSurrogateMaximum
                && index + 1 < text.length
            ) {
                const nextCodeUnit = text.charCodeAt(index + 1)
                if (nextCodeUnit >= manabiLowSurrogateMinimum && nextCodeUnit <= manabiLowSurrogateMaximum) {
                    codeUnitLength = 2
                }
            }
            index += codeUnitLength
            codePointCount += 1
        }
        if (escapedParts.length === 0) {
            return index === text.length ? text : text.slice(0, index)
        }
        if (chunkStart < index) {
            escapedParts.push(text.slice(chunkStart, index))
        }
        return escapedParts.join('')
    }

    // The current compact schema derives examples from sidecar tuples on demand. This avoids
    // serializing the same sentence facts twice and keeps sentence HTML assembly off the initial
    // render path.
    const manabiSentenceArchiveEntryFromSidecarSegments = (segments) => {
        let text = ''
        const sentenceJMDictIDs = []
        const sentenceJMDictIDSet = new Set()
        const vocabularyCandidateGroups = []
        const archiveSegments = []
        for (const segment of segments) {
            text += segment.x || segment.s || segment.ns || ''
            const jmdictEntryIDs = manabiSidecarNumberArray(segment.j)
            const jmnedictEntryIDs = manabiSidecarNumberArray(segment.n)
            const primaryEntryID = jmdictEntryIDs[0]
            if (Number.isFinite(primaryEntryID) && !sentenceJMDictIDSet.has(primaryEntryID)) {
                sentenceJMDictIDSet.add(primaryEntryID)
                sentenceJMDictIDs.push(primaryEntryID)
            }
            if (jmdictEntryIDs.length > 0 || jmnedictEntryIDs.length > 0) {
                vocabularyCandidateGroups.push({
                    jmdictEntryIds: jmdictEntryIDs,
                    // Preserve both typed alternative sets. Primary selection is a
                    // native policy; the sidecar must not erase dictionary identity.
                    jmnedictEntryIds: jmnedictEntryIDs,
                })
            }
            const segmentIdentifier = segment.sid || ''
            if (segmentIdentifier) {
                archiveSegments.push({
                    jmdictEntryIds: jmdictEntryIDs,
                    jmnedictEntryIds: jmnedictEntryIDs,
                    searchString: segment.s || segment.ns || '',
                    segmentIdentifier,
                })
            }
        }

        const sentenceHTML = manabiEscapedExampleSentenceHTML(text)
        for (const segment of archiveSegments) {
            segment.exampleSentence = sentenceHTML
            segment.exampleSentenceJMDictIDs = sentenceJMDictIDs
        }
        return {
            sentenceHTML,
            sentenceJMDictIDs,
            vocabularyCandidateGroups,
            segments: archiveSegments,
        }
    }

    const directSegmentMetadataBootstrap = (doc) => {
        // Document caches can be shared by factories; schema admission precedes cache reuse.
        if (!doc || !manabiSegmentSidecarSchemaIsCompatible) {
            return emptySegmentMetadataBootstrap()
        }
        const { sidecars, sidecarTexts, sidecarPayloads = [], sidecarSignature } = manabiSegmentMetadataSidecarSnapshot(doc)
        const cachedByID = doc.__manabiFoliateSegmentMetadataByID
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
            }
        }
        const idsByEntryID = new Map()
        const segments = []
        const sentenceArchive = new Map()
        let payload = sidecarPayloads[0] ?? null
        if (!payload && sidecarTexts[0]) {
            try {
                payload = JSON.parse(sidecarTexts[0])
            } catch (_error) {}
        }
        const byID = new ManabiLazySegmentMetadataMap(payload)
        const segmentIDsBySentenceID = new ManabiLazySegmentScopeMap(
            byID.compactSegments,
            byID.tables?.sid ?? [],
            9
        )
        const segmentIDsByParagraphID = new ManabiLazySegmentScopeMap(
            byID.compactSegments,
            byID.tables?.pid ?? [],
            10
        )
        const tableHasEntryIDs = (table) => table?.some?.(entryIDs => entryIDs?.some?.(Number.isFinite) === true) === true
        const hasEntryIDs = tableHasEntryIDs(byID.tables?.j) || tableHasEntryIDs(byID.tables?.n)
        // Keep the existing Map contract while moving sentence string assembly to the lookup that
        // requests it. The segment index above makes each materialization sentence-local.
        const cachedSentenceArchiveEntry = sentenceArchive.get.bind(sentenceArchive)
        sentenceArchive.get = (sentenceID) => {
            const cachedEntry = cachedSentenceArchiveEntry(sentenceID)
            if (cachedEntry) return cachedEntry
            const sentenceSegmentIDs = segmentIDsBySentenceID.get(sentenceID)
            if (!Array.isArray(sentenceSegmentIDs) || sentenceSegmentIDs.length === 0) return undefined
            const sentenceSegments = sentenceSegmentIDs
                .map(segmentID => byID.get(segmentID) ?? null)
                .filter(Boolean)
            if (sentenceSegments.length === 0) return undefined
            const entry = manabiSentenceArchiveEntryFromSidecarSegments(sentenceSegments)
            sentenceArchive.set(sentenceID, entry)
            return entry
        }
        doc.__manabiFoliateSegmentMetadataParserVersion = manabiSegmentSidecarParserVersion
        doc.__manabiFoliateSegmentMetadataSignature = sidecarSignature
        doc.__manabiFoliateSegmentMetadataByID = byID
        doc.__manabiFoliateSegmentIDsByEntryID = idsByEntryID
        doc.__manabiFoliateSegmentMetadataHasEntryIDs = hasEntryIDs
        doc.__manabiFoliateSegmentIDsBySentenceID = segmentIDsBySentenceID
        doc.__manabiFoliateSegmentIDsByParagraphID = segmentIDsByParagraphID
        doc.__manabiFoliateSegmentMetadataSegments = segments
        doc.__manabiFoliateSidecarSentenceArchive = sentenceArchive
        // manabi_reader.js owns the general reader cache, but processed EPUB documents are
        // immutable and use this compact bootstrap first. Publish the same lazy structures under
        // that cache contract so a later lookup cannot eagerly expand the entire sidecar again.
        doc.manabiSegmentMetadataParserVersion = manabiSegmentSidecarParserVersion
        doc.manabiSegmentMetadataByID = byID
        doc.manabiSegmentIDsByEntryID = idsByEntryID
        doc.manabiSegmentIDsBySentenceID = segmentIDsBySentenceID
        doc.manabiSegmentIDsByParagraphID = segmentIDsByParagraphID
        doc.manabiSegmentMetadataSegments = segments
        doc.manabiSegmentMetadataAggregates = null
        doc.manabiSidecarSentenceArchive = sentenceArchive
        doc.manabiSegmentMetadataSidecars = sidecars
        doc.manabiSegmentMetadataSidecarTexts = sidecarTexts
        doc.manabiSegmentMetadataSidecarSignature = sidecarSignature
        doc.manabiSegmentMetadataCacheGeneration = doc.manabiSegmentMetadataGeneration || 0
        return {
            byID,
            idsByEntryID,
            hasEntryIDs,
            segmentIDsBySentenceID,
            segmentIDsByParagraphID,
            segments,
            aggregates: null,
            sentenceArchive,
        }
    }

    return { bootstrap: directSegmentMetadataBootstrap, schemaDiagnostics }
}
