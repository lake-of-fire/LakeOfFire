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
