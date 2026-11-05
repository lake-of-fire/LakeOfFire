import { makeNativeEbookSource, nativeEbookRequest } from './ebook-native-source-request.js'
import { makeDirectSectionURLResolver } from './ebook-direct-section.js'

const superseded = () => {
    const error = new Error('Reader open was superseded')
    error.code = 'reader-open-superseded'
    return error
}

// The viewer and cache warmer use this same native loader. The native-issued
// source/rendition stays captured; never rediscover it from globalThis.reader.
export const createNativeEpubLoader = async (value, isCacheWarmer, {
    isCurrent = () => true,
    fetch: fetchResource = globalThis.fetch,
    makeReplaceText,
} = {}) => {
    const source = makeNativeEbookSource(value?.url, value?.packageSessionID)
    if (!isCurrent()) throw superseded()
    const catalogRequest = nativeEbookRequest('entries', source.url, source)
    const response = await fetchResource(catalogRequest.url, { headers: catalogRequest.headers })
    if (!isCurrent()) throw superseded()
    if (!response.ok) throw new Error(`Failed to load native EPUB entries: ${response.status}`)
    const { entries: rawEntries = [], packageDocumentPath = null } = await response.json()
    if (!isCurrent()) throw superseded()
    const entries = rawEntries.map(entry => ({ filename: entry.path, uncompressedSize: entry.size ?? 0 }))
    const sizeMap = new Map(entries.map(entry => [entry.filename, entry.uncompressedSize]))
    const entryNames = new Set(entries.map(entry => entry.filename))
    // A bound opening cannot silently pick the first OPF or a missing resource.
    if (source.packageSessionID != null && (typeof packageDocumentPath !== 'string'
        || !entryNames.has(packageDocumentPath))) {
        throw new Error('Missing native EPUB rendition')
    }
    let destroyed = false
    const isActive = () => !destroyed && isCurrent()
    const responseFor = async name => {
        if (!isActive() || !entryNames.has(name)) return null
        const request = nativeEbookRequest('entry', source.url, { ...source, subpath: name })
        const response = await fetchResource(request.url, { headers: request.headers })
        return isActive() && response.ok ? response : null
    }
    const loadText = async name => {
        const response = await responseFor(name)
        if (!response) return null
        const data = await response.arrayBuffer()
        if (!isActive()) return null
        const charset = response.headers?.get?.('content-type')?.match(/charset=([^;]+)/i)?.[1]?.trim() || 'utf-8'
        let decoder
        try { decoder = new TextDecoder(charset) }
        catch { decoder = new TextDecoder('utf-8') }
        return decoder.decode(data)
    }
    const replaceText = makeReplaceText(isCacheWarmer, source)
    const replaceURL = makeDirectSectionURLResolver(source.url, isCacheWarmer, loadText, source.packageSessionID)
    return {
        entries,
        packageDocumentPath: source.packageSessionID == null ? null : packageDocumentPath,
        loadText,
        loadBlob: async name => {
            const response = await responseFor(name)
            if (!response) return null
            const data = await response.arrayBuffer()
            if (!isActive()) return null
            const type = response.headers?.get?.('content-type') || ''
            return new Blob([data], type ? { type } : undefined)
        },
        getSize: name => isActive() ? (sizeMap.get(name) ?? 0) : 0,
        replaceText,
        replaceURL,
        sourceURL: source.url,
        destroy: () => {
            if (destroyed) return false
            destroyed = true
            replaceURL?.destroy?.()
            entryNames.clear()
            sizeMap.clear()
            entries.length = 0
            return true
        },
    }
}
