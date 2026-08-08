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

export const getPrimaryRendererContentIndex = renderer => {
    const currentIndex = rendererCurrentIndex(renderer)
    if (currentIndex !== null) return currentIndex
    const primaryContent = rendererContents(renderer)[0] ?? null
    return Number.isInteger(primaryContent?.index) ? primaryContent.index : null
}

export const getPrimaryRendererContent = renderer => {
    const contents = rendererContents(renderer)
    const currentIndex = rendererCurrentIndex(renderer)
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
    const contents = rendererContents(renderer)
    const currentIndex = rendererCurrentIndex(renderer)
        ?? (Number.isInteger(contents[0]?.index) ? contents[0].index : null)
    return Number.isInteger(currentIndex)
        ? contents.filter(content => content?.index === currentIndex)
        : contents
}
