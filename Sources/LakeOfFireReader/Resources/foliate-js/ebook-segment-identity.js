const nonEmptyString = value => typeof value === 'string' && value.length > 0
    ? value
    : null

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
