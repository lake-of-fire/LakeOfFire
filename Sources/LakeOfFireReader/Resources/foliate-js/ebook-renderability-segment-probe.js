export const visibleSegmentProbeAcceptsIdentity = ({
    includeSegmentMetadata = true,
    segmentIdentifier = null,
} = {}) => (
    includeSegmentMetadata === false
    || (typeof segmentIdentifier === 'string' && segmentIdentifier.length > 0)
)

export const boundedRenderabilityAnchorSegment = (doc, visibleRange = null) => {
    const startContainer = visibleRange?.startContainer ?? null
    const startElement = startContainer?.nodeType === 1
        ? startContainer
        : startContainer?.parentElement ?? null

    return startElement?.closest?.('m-m')
        ?? startElement?.querySelector?.('m-m')
        ?? doc?.body?.querySelector?.('m-m')
        ?? null
}
