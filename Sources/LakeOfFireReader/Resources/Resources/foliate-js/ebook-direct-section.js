import { normalizeEbookPackageSessionID } from './ebook-native-source-request.js'
export const processedSectionURLForHref = (sourceURL, href, writingDirection = null, packageSessionID = null) => {
    if (typeof sourceURL !== 'string' || sourceURL.length === 0) return null
    if (typeof href !== 'string' || href.length === 0) return null
    const params = new URLSearchParams({ sourceURL, subpath: href, direct: '1' })
    const sessionID = normalizeEbookPackageSessionID(packageSessionID)
    if (sessionID !== null) params.set('packageSessionID', sessionID)
    if (writingDirection?.direction) params.set('mnbWritingDirection', writingDirection.direction)
    if (writingDirection?.writingMode) params.set('mnbWritingMode', writingDirection.writingMode)
    return `ebook://ebook/processed-section?${params.toString()}`
}

export const prepareWritingDirectionStylesheets = async ({
    head, loadText, resolveArchivePath, signal, blobURLs,
}) => {
    const stylesheetLinks = Array.from(head.querySelectorAll?.('link[rel="stylesheet"][href]') ?? [])
    for (const link of stylesheetLinks) {
        if (signal?.aborted) return
        const path = resolveArchivePath?.(link.getAttribute('href'))
        if (!path) continue
        try {
            const css = await loadText?.(path, { signal })
            if (signal?.aborted) return
            if (!css) continue
            const url = URL.createObjectURL(new Blob([css], { type: 'text/css' }))
            blobURLs.push(url)
            link.href = url
        } catch (_error) {}
    }
}
