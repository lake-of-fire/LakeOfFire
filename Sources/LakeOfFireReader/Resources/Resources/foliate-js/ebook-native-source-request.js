// One immutable native-issued package capability per opening. Null is the
// explicit legacy path; malformed/present tokens never degrade to legacy.
export const normalizeEbookPackageSessionID = value => {
    if (value == null) return null
    if (typeof value !== 'string'
        || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value)) {
        throw new TypeError('Invalid native EPUB package session')
    }
    return value
}

export const makeNativeEbookSource = (url, packageSessionID = null) => {
    if (typeof url !== 'string' || !url.startsWith('ebook://ebook/load/')) {
        throw new TypeError('Invalid native EPUB source')
    }
    return Object.freeze({ kind: 'native', url,
        packageSessionID: normalizeEbookPackageSessionID(packageSessionID) })
}

export const nativeEbookRequest = (route, sourceURL, { subpath = null, packageSessionID = null } = {}) => {
    if (route !== 'entries' && route !== 'entry') throw new TypeError('Invalid native EPUB route')
    const source = makeNativeEbookSource(sourceURL, packageSessionID)
    const query = new URLSearchParams({ sourceURL: source.url })
    if (subpath !== null) query.set('subpath', subpath)
    const headers = { 'X-Ebook-Source-URL': source.url }
    if (source.packageSessionID !== null) {
        query.set('packageSessionID', source.packageSessionID)
        headers['X-Ebook-Package-Session'] = source.packageSessionID
    }
    return { url: `ebook://ebook/${route}?${query}`, headers }
}

// The native descriptor pins a declared literal OPF path, not just ZIP bytes.
// Legacy callers retain the previous first-rendition behavior.
export const selectedEbookPackageDocument = (opfs, nativePath = null) => {
    if (nativePath == null) return opfs[0]?.fullPath ?? null
    if (typeof nativePath !== 'string' || nativePath.length === 0
        || !opfs.some(file => file.fullPath === nativePath)) {
        throw new Error('Native EPUB rendition does not match the declared package')
    }
    return nativePath
}
