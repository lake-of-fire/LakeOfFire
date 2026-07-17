const contentScriptFrameIdentifier = doc => {
    const view = doc?.defaultView ?? null
    return doc?.body?.dataset?.swiftuiwebviewFrameUuid
        || doc?.documentElement?.dataset?.swiftuiwebviewFrameUuid
        || view?.manabiCurrentFrameUUID?.()
        || null
}

export const ebookDocumentFrameIdentity = doc => {
    if (!doc || typeof doc !== 'object') return null
    const documentURL = doc.location?.href || doc.URL || null
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
