const canonicalDocumentURL = value => {
    if (typeof value !== 'string' || value.length === 0) return null
    const hashIndex = value.indexOf('#')
    return hashIndex >= 0 ? value.slice(0, hashIndex) : value
}

const contentScriptFrameIdentifier = doc => {
    const view = doc?.defaultView ?? null
    return doc?.body?.dataset?.swiftuiwebviewFrameUuid
        || doc?.documentElement?.dataset?.swiftuiwebviewFrameUuid
        || view?.manabiCurrentFrameUUID?.()
        || null
}

export const ebookDocumentFrameIdentity = doc => {
    if (!doc || typeof doc !== 'object') return null
    const documentURL = canonicalDocumentURL(doc.location?.href || doc.URL || null)
    const frameIdentifier = contentScriptFrameIdentifier(doc)
    if (!documentURL || !frameIdentifier) return null
    return {
        documentURL,
        frameIdentifier,
        frameKey: `${documentURL}|${frameIdentifier}`,
    }
}

export const shouldPublishForDocumentFrame = ({
    scheduledGeneration,
    currentGeneration,
    explicitDocument = null,
    currentDocuments = [],
}) => scheduledGeneration === currentGeneration
    && (!explicitDocument || currentDocuments.includes(explicitDocument))

export const nativeLookupFramePublicationTransition = ({
    previousFrameKey = null,
    document,
}) => {
    const identity = ebookDocumentFrameIdentity(document)
    if (!identity) {
        return {
            frameKey: null,
            shouldResetPreviousTargets: false,
        }
    }
    return {
        frameKey: identity.frameKey,
        // The reset intentionally has no frame key at its call site: it is a
        // destructive ordering barrier for every prior frame publication.
        shouldResetPreviousTargets: typeof previousFrameKey === 'string'
            && previousFrameKey.length > 0
            && previousFrameKey !== identity.frameKey,
    }
}
