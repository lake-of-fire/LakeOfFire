export const processedSectionURLForHref = (sourceURL, href) => {
    if (typeof sourceURL !== 'string' || sourceURL.length === 0) return null
    if (typeof href !== 'string' || href.length === 0) return null
    const query = new URLSearchParams({
        sourceURL,
        subpath: href,
        direct: '1',
    })
    return `ebook://ebook/processed-section?${query.toString()}`
}

export const makeDirectSectionURLResolver = (sourceURL, isCacheWarmer) => {
    if (isCacheWarmer) return null
    return async (href) => processedSectionURLForHref(sourceURL, href)
}
