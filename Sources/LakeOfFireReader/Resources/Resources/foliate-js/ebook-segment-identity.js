const nonEmptyString = value => typeof value === 'string' && value.length > 0
    ? value
    : null

const compactMnbSegmentTokenPattern = /^[0-9A-Za-z]+$/

export const compactEbookSegmentSidecarVersion = 12
export const stableEbookSegmentIdentityVersion = 1

export const compactEbookSegmentSchemaVersionsAreCompatible = nativeVersion => (
    Number.isSafeInteger(nativeVersion)
    && nativeVersion === compactEbookSegmentSidecarVersion
)

export const expandCompactEbookSegmentIDToken = token => {
    if (typeof token !== 'string' || token.length === 0) return null
    if (token.startsWith('!')) return nonEmptyString(token.slice(1))
    if (token.startsWith('~')) {
        const suffix = nonEmptyString(token.slice(1))
        return suffix === null ? null : `_m${suffix}`
    }
    return compactMnbSegmentTokenPattern.test(token) ? `mnb-s${token}` : null
}

export const compactEbookSegmentRuntimeIDsAreUnique = segments => {
    if (!Array.isArray(segments)) return false
    const runtimeIDs = new Set()
    return segments.every(segment => {
        if (!Array.isArray(segment) || segment.length < 11 || segment.length > 12) return false
        const runtimeID = expandCompactEbookSegmentIDToken(segment[0])
        if (runtimeID === null || runtimeIDs.has(runtimeID)) return false
        runtimeIDs.add(runtimeID)
        return true
    })
}

const compactSegmentTableValue = (table, index) => (
    Number.isInteger(index) && Array.isArray(table) && index >= 0 && index < table.length
        ? table[index]
        : null
)

const optionalTableReferenceIsValid = (table, index, valueIsValid) => {
    if (index === null) return true
    const value = compactSegmentTableValue(table, index)
    return value !== null && valueIsValid(value)
}

const entryIDArrayIsValid = value => Array.isArray(value)
    && value.every(entryID => Number.isSafeInteger(entryID) && entryID > 0)

const nonEmptyStringIsValid = value => typeof value === 'string' && value.length > 0

const entryIDTableIsValid = value => Array.isArray(value) && value.every(entryIDArrayIsValid)

const stringTableIsValid = value => Array.isArray(value) && value.every(nonEmptyStringIsValid)

const resolutionTableIsValid = value => Array.isArray(value)
    && value.every(resolution => resolution !== null
        && typeof resolution === 'object'
        && !Array.isArray(resolution))

const compactSegmentTablesAreCurrent = tables => (
    entryIDTableIsValid(tables?.j)
    && entryIDTableIsValid(tables?.n)
    && stringTableIsValid(tables?.s)
    && stringTableIsValid(tables?.ns)
    && stringTableIsValid(tables?.p)
    && stringTableIsValid(tables?.h)
    && stringTableIsValid(tables?.sid)
    && stringTableIsValid(tables?.pid)
    && (tables?.x == null || stringTableIsValid(tables.x))
    && (tables?.res == null || resolutionTableIsValid(tables.res))
    && (tables?.f == null || stringTableIsValid(tables.f))
)

const compactSegmentTupleIsCurrent = (segment, tables) => {
    if (!Array.isArray(segment) || segment.length < 11 || segment.length > 12) return false
    if (expandCompactEbookSegmentIDToken(segment[0]) === null) return false
    return [
        compactSegmentTableValue(tables?.h, segment[1]),
        compactSegmentTableValue(tables?.sid, segment[9]),
        compactSegmentTableValue(tables?.pid, segment[10]),
    ].every(nonEmptyStringIsValid)
        && optionalTableReferenceIsValid(tables?.j, segment[2], entryIDArrayIsValid)
        && optionalTableReferenceIsValid(tables?.n, segment[3], entryIDArrayIsValid)
        && optionalTableReferenceIsValid(tables?.s, segment[4], nonEmptyStringIsValid)
        && optionalTableReferenceIsValid(tables?.ns, segment[5], nonEmptyStringIsValid)
        && optionalTableReferenceIsValid(tables?.p, segment[6], nonEmptyStringIsValid)
        && (segment[7] === null
            || (Number.isSafeInteger(segment[7]) && segment[7] >= 1 && segment[7] <= 5))
        && optionalTableReferenceIsValid(tables?.x, segment[8], nonEmptyStringIsValid)
        && (segment.length === 11
            || optionalTableReferenceIsValid(
                tables?.res,
                segment[11],
                value => expandCompactEbookSegmentResolution(
                    value,
                    compactSegmentTableValue(tables?.j, segment[2]) ?? [],
                    compactSegmentTableValue(tables?.n, segment[3]) ?? []
                ) !== null
            ))
}

export const expandCompactEbookSegmentResolution = (
    resolution,
    jmdictEntryIDs,
    jmnedictEntryIDs
) => {
    if (resolution === null || typeof resolution !== 'object' || Array.isArray(resolution)) {
        return null
    }
    const selected = resolution.se
    const selectedLexicon = selected?.namespace === 'jmdict'
        || selected?.namespace === 'jmnedict'
        ? selected.namespace
        : (Number.isSafeInteger(resolution.e) && resolution.e > 0 ? 'jmdict' : null)
    const selectedEntryID = Number.isSafeInteger(selected?.entryID) && selected.entryID > 0
        ? selected.entryID
        : (selectedLexicon === 'jmdict'
            && Number.isSafeInteger(resolution.e)
            && resolution.e > 0
            ? resolution.e
            : null)
    const selectedCandidates = selectedLexicon === 'jmdict'
        ? jmdictEntryIDs
        : selectedLexicon === 'jmnedict'
            ? jmnedictEntryIDs
            : []
    if (selectedLexicon !== null
        && (!Number.isSafeInteger(selectedEntryID)
            || !selectedCandidates.includes(selectedEntryID))) {
        return null
    }
    return {
        selectedLexicon,
        selectedEntryID,
        canonicalSearchString: nonEmptyString(resolution.s),
    }
}

export const compactEbookSegmentMetadataPayloadIsCurrent = payload => (
    payload?.v === compactEbookSegmentSidecarVersion
    && compactSegmentTablesAreCurrent(payload?.t)
    && Array.isArray(payload?.s)
    && compactEbookSegmentRuntimeIDsAreUnique(payload.s)
    && payload.s.every(segment => compactSegmentTupleIsCurrent(segment, payload.t))
)

export const ebookSegmentIdentity = (segmentNode, metadata = null) => {
    const elementID = nonEmptyString(segmentNode?.id)
        ?? nonEmptyString(segmentNode?.getAttribute?.('id'))
    const metadataElementID = nonEmptyString(metadata?.i)
    const stableID = nonEmptyString(metadata?.sid)

    return {
        elementID,
        metadataElementID,
        stableID,
        segmentIdentifier: stableID,
        hasSidecarStableID: stableID !== null,
    }
}

export const ebookSegmentIdentifierAliases = (segmentNode, metadata = null) => {
    const stableID = ebookSegmentIdentity(segmentNode, metadata).stableID
    return stableID === null ? [] : [stableID]
}
