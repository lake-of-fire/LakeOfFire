let generatedFrameIdentifierSequence = 0

const generatedFrameIdentifiers = new WeakMap()

const existingFrameIdentifier = doc => doc?.body?.dataset?.swiftuiwebviewFrameUuid
    || doc?.documentElement?.dataset?.swiftuiwebviewFrameUuid
    || null

const generateFrameIdentifier = doc => {
    const view = doc?.defaultView ?? null
    try {
        if (typeof view?.crypto?.randomUUID === 'function') return view.crypto.randomUUID()
    } catch (_error) {}
    generatedFrameIdentifierSequence += 1
    return `ebook-frame-${generatedFrameIdentifierSequence}`
}

export const nativeLookupPublicationIdentityForDocument = doc => {
    if (!doc || typeof doc !== 'object') return null
    const documentURL = doc.location?.href || doc.URL || null
    let frameIdentifier = existingFrameIdentifier(doc) || generatedFrameIdentifiers.get(doc) || null
    if (!frameIdentifier) {
        frameIdentifier = generateFrameIdentifier(doc)
        generatedFrameIdentifiers.set(doc, frameIdentifier)
        const dataset = doc.body?.dataset ?? doc.documentElement?.dataset ?? null
        if (dataset) dataset.swiftuiwebviewFrameUuid = frameIdentifier
    }
    return {
        documentURL,
        frameIdentifier,
        frameKey: documentURL ? `${documentURL}|${frameIdentifier}` : frameIdentifier,
    }
}

export const shouldRunNativeLookupRefresh = ({
    scheduledGeneration,
    currentGeneration,
    explicitDocument = null,
    currentDocuments = [],
}) => {
    if (scheduledGeneration !== currentGeneration) return false
    if (!explicitDocument) return true
    return currentDocuments.includes(explicitDocument)
}
