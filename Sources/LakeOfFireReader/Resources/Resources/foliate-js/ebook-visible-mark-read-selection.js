// Visibility supplies identities only. All durable selection facts and scope
// membership come from the immutable Swift-produced section sidecar.
export const visibleMarkReadSidecarSelection = ({
    visibleSegmentIdentifiers = [],
    metadataByID,
    segmentIDsBySentenceID,
} = {}) => {
    const selected = new Map();
    for (const identifier of visibleSegmentIdentifiers) {
        if (typeof identifier !== 'string' || identifier.length === 0) return null;
        const metadata = metadataByID?.get?.(identifier);
        if (typeof metadata?.sid !== 'string' || metadata.sid.length === 0
            || (identifier !== metadata.sid && identifier !== metadata.i)
            || typeof metadata.sentenceID !== 'string' || metadata.sentenceID.length === 0) return null;
        const members = segmentIDsBySentenceID?.get?.(metadata.sentenceID);
        if (!Array.isArray(members)
            || !members.some(member => member === metadata.i || member === metadata.sid)) return null;
        selected.set(metadata.sid, metadata);
    }
    return Array.from(selected.values());
};


// A sentence in the native read projection covers all its segments, even when
// the projection omits individually enumerated readSegmentIdentifiers. The
// visible-page label must use both supported forms of native read evidence.
export const visibleMarkReadSegmentIsRead = (
    segmentIdentifier, item, readSegmentIdentifiers, readSentenceIdentifiers
) => {
    if (typeof item?.sentenceIdentifier === 'string'
        && item.sentenceIdentifier.length > 0
        && readSentenceIdentifiers.has(item.sentenceIdentifier)) return true
    const aliases = Array.isArray(item?.segmentIdentifierAliases)
        && item.segmentIdentifierAliases.length > 0
        ? item.segmentIdentifierAliases
        : [segmentIdentifier]
    return aliases.some(identifier => readSegmentIdentifiers.has(identifier))
}
