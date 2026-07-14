export const processedSectionURLForHref = (sourceURL, href, writingDirection = null) => {
    if (typeof sourceURL !== 'string' || sourceURL.length === 0) return null
    if (typeof href !== 'string' || href.length === 0) return null
    const params = new URLSearchParams({ sourceURL, subpath: href, direct: '1' })
    if (writingDirection?.direction) params.set('mnbWritingDirection', writingDirection.direction)
    if (writingDirection?.writingMode) params.set('mnbWritingMode', writingDirection.writingMode)
    return `ebook://ebook/processed-section?${params.toString()}`
}
