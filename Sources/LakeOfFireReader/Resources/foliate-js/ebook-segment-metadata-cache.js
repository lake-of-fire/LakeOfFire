import {
    compactEbookSegmentMetadataPayloadIsExactV9,
    expandCompactEbookSegmentIDToken,
} from './ebook-segment-identity.js'

const makeCacheEntry = () => ({
    byRuntimeID: new Map(),
    rejectedRuntimeIDs: new Set(),
    payloads: null,
    sidecars: [],
    sidecarTexts: [],
    sidecarSignature: '',
})

const nonemptyAttribute = (element, name, datasetName) => {
    const value = element?.dataset?.[datasetName] ?? element?.getAttribute?.(name) ?? null
    return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null
}

export const ebookSegmentSidecarRevision = document => {
    const transportMarkers = Array.from(document?.getElementsByTagName?.('meta') || [])
        .filter(marker => marker?.getAttribute?.('name') === 'mnb-pretransformed-ebook-sidecar')
    if (transportMarkers.length > 0) {
        const revision = transportMarkers.length === 1
            ? nonemptyAttribute(
                transportMarkers[0],
                'data-mnb-sidecar-revision',
                'mnbSidecarRevision',
            )
            : null
        return revision
            ? `transport:${revision}`
            : `invalid-transport-owner-count:${transportMarkers.length}`
    }

    const canonicalSidecars = Array.from(document?.getElementsByTagName?.('script') || [])
        .filter(sidecar => sidecar?.id === 'mnb-segment-metadata')
    if (canonicalSidecars.length > 0) {
        const revision = canonicalSidecars.length === 1
            ? nonemptyAttribute(
                canonicalSidecars[0],
                'data-mnb-sidecar-revision',
                'mnbSidecarRevision',
            )
            : null
        return revision
            ? `inline:${revision}`
            : `invalid-inline-owner-count:${canonicalSidecars.length}`
    }

    const externalSignature = document?.manabiExternalSegmentSidecar?.signature
    return typeof externalSignature === 'string' && externalSignature.length > 0
        ? `external:${externalSignature}`
        : null
}

export const createEbookSegmentMetadataDocumentCache = () => {
    const cacheByDocument = new WeakMap()
    return {
        entryForDocument(document) {
            let entry = cacheByDocument.get(document)
            if (entry) return entry
            entry = makeCacheEntry()
            cacheByDocument.set(document, entry)
            return entry
        },
    }
}

const metadataSidecarsForDocument = document => {
    const scripts = Array.from(document?.getElementsByTagName?.('script') || [])
    let sidecars = scripts.filter(script => (
        script?.id === 'mnb-segment-metadata'
        || script?.hasAttribute?.('data-mnb-seg-meta') === true
    ))
    const primarySidecar = document?.getElementById?.('mnb-segment-metadata') ?? null
    if (primarySidecar && !sidecars.includes(primarySidecar)) {
        sidecars = [primarySidecar, ...sidecars]
    }
    const inlineCanonicalSidecars = sidecars.filter(sidecar => (
        sidecar?.id === 'mnb-segment-metadata'
    ))
    if (inlineCanonicalSidecars.length > 1) {
        sidecars = sidecars.filter(sidecar => sidecar?.id !== 'mnb-segment-metadata')
    }
    const hasAnyInlineCanonicalSidecar = inlineCanonicalSidecars.length > 0
    const externalCanonicalSidecar = document?.manabiExternalSegmentSidecar?.sidecar ?? null
    if (!hasAnyInlineCanonicalSidecar
        && externalCanonicalSidecar
        && !sidecars.includes(externalCanonicalSidecar)) {
        sidecars = [externalCanonicalSidecar, ...sidecars]
    }
    return sidecars
}

const metadataSidecarSnapshot = document => {
    const sidecars = metadataSidecarsForDocument(document)
    const sidecarTexts = sidecars.map(sidecar => sidecar.textContent || '')
    const externalSignature = document?.manabiExternalSegmentSidecar?.signature
    return {
        sidecars,
        sidecarTexts,
        sidecarSignature: typeof externalSignature === 'string' ? externalSignature : '',
    }
}

const snapshotMatchesCache = (cache, snapshot) => (
    cache.sidecarSignature === snapshot.sidecarSignature
    && cache.sidecars.length === snapshot.sidecars.length
    && cache.sidecarTexts.length === snapshot.sidecarTexts.length
    && cache.sidecars.every((sidecar, index) => sidecar === snapshot.sidecars[index])
    && cache.sidecarTexts.every((text, index) => text === snapshot.sidecarTexts[index])
)

const updateCachedSnapshot = (cache, snapshot) => {
    cache.sidecars = snapshot.sidecars
    cache.sidecarTexts = snapshot.sidecarTexts
    cache.sidecarSignature = snapshot.sidecarSignature
}

const resetCacheForSnapshot = (cache, snapshot) => {
    cache.byRuntimeID = new Map()
    cache.rejectedRuntimeIDs = new Set()
    cache.payloads = null
    updateCachedSnapshot(cache, snapshot)
}

const tableValue = (table, index, fallback = null) => (
    Number.isInteger(index) && Array.isArray(table) && index >= 0 && index < table.length
        ? table[index]
        : fallback
)

const compactTables = tables => ({
    h: tables.h,
    j: tables.j,
    n: tables.n,
    s: tables.s,
    ns: tables.ns,
    p: tables.p,
    x: Array.isArray(tables.x) ? tables.x : [],
    sid: tables.sid,
    pid: tables.pid,
})

const metadataFromTuple = (segment, tables) => {
    const segmentHash = tableValue(tables.h, segment[1])
    const sentenceIdentifier = tableValue(tables.sid, segment[9])
    const paragraphIdentifier = tableValue(tables.pid, segment[10])
    return {
        i: expandCompactEbookSegmentIDToken(segment[0]),
        h: segmentHash,
        sid: `${sentenceIdentifier}-${segmentHash}`,
        sentenceID: sentenceIdentifier,
        paragraphID: paragraphIdentifier,
        pid: paragraphIdentifier,
        j: tableValue(tables.j, segment[2], []),
        n: tableValue(tables.n, segment[3], []),
        s: tableValue(tables.s, segment[4]),
        ns: tableValue(tables.ns, segment[5]),
        p: tableValue(tables.p, segment[6]),
        l: segment[7],
        x: tableValue(tables.x, segment[8]),
    }
}

const validatedPayloadRecord = sidecar => {
    let payload
    try {
        payload = JSON.parse(sidecar.textContent || '{}')
    } catch (_error) {
        return null
    }
    if (!compactEbookSegmentMetadataPayloadIsExactV9(payload)) return null
    return {
        payload,
        tables: compactTables(payload.t),
        byRuntimeID: new Map(),
        scannedThrough: -1,
        complete: false,
    }
}

const payloadRecordsForSnapshot = (cache, snapshot) => {
    if (snapshotMatchesCache(cache, snapshot) && Array.isArray(cache.payloads)) {
        return cache.payloads
    }
    const payloads = snapshot.sidecars
        .map(validatedPayloadRecord)
        .filter(payload => payload !== null)
    cache.payloads = payloads
    updateCachedSnapshot(cache, snapshot)
    return payloads
}

const findMetadataInPayload = (record, runtimeID) => {
    if (record.byRuntimeID.has(runtimeID)) {
        return metadataFromTuple(
            record.payload.s[record.byRuntimeID.get(runtimeID)],
            record.tables,
        )
    }
    if (record.complete) return null
    for (let index = record.scannedThrough + 1; index < record.payload.s.length; index += 1) {
        const segment = record.payload.s[index]
        const metadata = metadataFromTuple(segment, record.tables)
        record.byRuntimeID.set(metadata.i, index)
        record.scannedThrough = index
        if (metadata.i === runtimeID) return metadata
    }
    record.complete = true
    return null
}

export const createEbookSegmentMetadataLookup = () => {
    const documentCache = createEbookSegmentMetadataDocumentCache()
    return {
        metadataForNode(segmentNode) {
            const document = segmentNode?.ownerDocument ?? null
            const runtimeID = segmentNode?.id || segmentNode?.getAttribute?.('id') || null
            if (!document || typeof runtimeID !== 'string' || runtimeID.length === 0) return null

            const snapshot = metadataSidecarSnapshot(document)
            const cache = documentCache.entryForDocument(document)
            if (!snapshotMatchesCache(cache, snapshot)) {
                resetCacheForSnapshot(cache, snapshot)
            }
            if (cache.byRuntimeID.has(runtimeID)) {
                return cache.byRuntimeID.get(runtimeID)
            }
            if (cache.rejectedRuntimeIDs.has(runtimeID)) return null

            let matchingMetadata = null
            for (const payload of payloadRecordsForSnapshot(cache, snapshot)) {
                const metadata = findMetadataInPayload(payload, runtimeID)
                if (!metadata) continue
                if (matchingMetadata !== null) {
                    cache.rejectedRuntimeIDs.add(runtimeID)
                    return null
                }
                matchingMetadata = metadata
            }
            if (matchingMetadata === null) {
                cache.rejectedRuntimeIDs.add(runtimeID)
                return null
            }
            cache.byRuntimeID.set(runtimeID, matchingMetadata)
            return matchingMetadata
        },
    }
}
