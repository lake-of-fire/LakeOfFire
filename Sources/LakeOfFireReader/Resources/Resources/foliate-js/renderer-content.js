export const rendererContents = renderer => {
    try {
        const contents = renderer?.getContents?.()
        return Array.isArray(contents) ? contents : []
    } catch (_error) {
        return []
    }
}

const rendererCurrentIndex = renderer => {
    try {
        const index = renderer?.currentIndex
        return Number.isInteger(index) ? index : null
    } catch (_error) {
        return null
    }
}

// A renderer can advance its navigation index before a replacement iframe is
// committed to the visible surface. Lookup publication must prefer the latter
// when the renderer makes it available.
const rendererDisplayedIndex = renderer => {
    try {
        const index = renderer?.displayedIndex
        return Number.isInteger(index) ? index : null
    } catch (_error) {
        return null
    }
}

const rendererPublicationIndex = renderer =>
    rendererDisplayedIndex(renderer) ?? rendererCurrentIndex(renderer)

const displayedContents = contents =>
    contents.filter(content => content?.isDisplayed !== false)

export const getPrimaryRendererContentIndex = renderer => {
    const currentIndex = rendererPublicationIndex(renderer)
    if (currentIndex !== null) return currentIndex
    const primaryContent = displayedContents(rendererContents(renderer))[0] ?? null
    return Number.isInteger(primaryContent?.index) ? primaryContent.index : null
}

export const getPrimaryRendererContent = renderer => {
    const contents = displayedContents(rendererContents(renderer))
    const currentIndex = rendererPublicationIndex(renderer)
    if (currentIndex !== null) {
        return contents.find(content => content?.index === currentIndex) ?? null
    }
    return contents[0] ?? null
}

export const getPrimaryRendererDocument = renderer => {
    const content = getPrimaryRendererContent(renderer)
    return content?.doc ?? content?.document ?? null
}

export const getCurrentRendererDocument = (renderer, explicitDocument = null) => {
    const primaryDocument = getPrimaryRendererDocument(renderer)
    if (explicitDocument !== null && explicitDocument !== undefined) {
        return explicitDocument === primaryDocument ? explicitDocument : null
    }
    return primaryDocument
}

export const activeRendererContentsForLookup = renderer => {
    const contents = displayedContents(rendererContents(renderer))
    const currentIndex = rendererPublicationIndex(renderer)
        ?? (Number.isInteger(contents[0]?.index) ? contents[0].index : null)
    return Number.isInteger(currentIndex)
        ? contents.filter(content => content?.index === currentIndex)
        : contents
}
