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
