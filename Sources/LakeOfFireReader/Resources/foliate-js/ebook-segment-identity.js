const nonEmptyString = value => typeof value === 'string' && value.length > 0
    ? value
    : null

const compactMnbSegmentTokenPattern = /^[0-9A-Za-z]+$/

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
        if (!Array.isArray(segment) || segment.length !== 11) return false
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

const compactSegmentTablesAreExactV9 = tables => (
    entryIDTableIsValid(tables?.j)
    && entryIDTableIsValid(tables?.n)
    && stringTableIsValid(tables?.s)
    && stringTableIsValid(tables?.ns)
    && stringTableIsValid(tables?.p)
    && stringTableIsValid(tables?.h)
    && stringTableIsValid(tables?.sid)
    && stringTableIsValid(tables?.pid)
    && (tables?.x == null || stringTableIsValid(tables.x))
)

const compactSegmentTupleIsExactV9 = (segment, tables) => {
    if (!Array.isArray(segment) || segment.length !== 11) return false
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
}

export const compactEbookSegmentMetadataPayloadIsExactV9 = payload => (
    payload?.v === 9
    && compactSegmentTablesAreExactV9(payload?.t)
    && Array.isArray(payload?.s)
    && compactEbookSegmentRuntimeIDsAreUnique(payload.s)
    && payload.s.every(segment => compactSegmentTupleIsExactV9(segment, payload.t))
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

export const indexUniqueEbookSegmentAlias = (
    aliasesByIdentifier,
    ambiguousIdentifiers,
    identifier,
    item,
) => {
    if (!identifier || ambiguousIdentifiers.has(identifier)) return false
    const existingItem = aliasesByIdentifier.get(identifier)
    if (existingItem && existingItem !== item) {
        aliasesByIdentifier.delete(identifier)
        ambiguousIdentifiers.add(identifier)
        return false
    }
    aliasesByIdentifier.set(identifier, item)
    return true
}

export const ebookSentenceIdentifier = sentenceNode =>
    nonEmptyString(sentenceNode?.getAttribute?.('sid'))
