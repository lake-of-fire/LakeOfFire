import { normalizeEbookPackageSessionID } from './ebook-native-source-request.js'
import { makeRawSectionWritingDirectionResolver } from './ebook-writing-direction.js'

export const processedSectionURLForHref = (sourceURL, href, writingDirection = null, packageSessionID = null) => {
    if (typeof sourceURL !== 'string' || sourceURL.length === 0) return null
    if (typeof href !== 'string' || href.length === 0) return null
    const query = new URLSearchParams({
        sourceURL,
        subpath: href,
        direct: '1',
    })
    const sessionID = normalizeEbookPackageSessionID(packageSessionID)
    if (sessionID !== null) query.set('packageSessionID', sessionID)
    if (writingDirection?.direction === 'vertical') {
        query.set('mnbWritingDirection', 'vertical')
        query.set(
            'mnbWritingMode',
            writingDirection.writingMode === 'vertical-lr' ? 'vertical-lr' : 'vertical-rl',
        )
    }
    return `ebook://ebook/processed-section?${query.toString()}`
}

export const makeDirectSectionURLResolver = (sourceURL, isCacheWarmer, loadText = null, packageSessionID = null) => {
    const sessionID = normalizeEbookPackageSessionID(packageSessionID)
    if (isCacheWarmer) return null
    const resolveWritingDirection = makeRawSectionWritingDirectionResolver({ loadText })
    let destroyed = false
    const resolver = async (href, mediaType) => {
        if (destroyed) return null
        if (mediaType !== 'application/xhtml+xml' && mediaType !== 'text/html') return null
        const writingDirection = await resolveWritingDirection(href)
        if (destroyed) return null
        return processedSectionURLForHref(sourceURL, href, writingDirection, sessionID)
    }
    resolver.destroy = () => {
        if (destroyed) return false
        destroyed = true
        resolveWritingDirection.destroy?.()
        return true
    }
    return resolver
}
