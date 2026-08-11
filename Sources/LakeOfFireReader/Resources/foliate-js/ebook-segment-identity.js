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
