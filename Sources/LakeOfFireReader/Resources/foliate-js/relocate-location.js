import { normalizedSectionIndex } from './progress.js'

export const buildRelocateLocation = ({
    reason,
    range,
    index,
    fraction,
    size,
    pageTurnDirection,
}, {
    sectionCount,
    sectionProgress,
    tocProgress,
    pageProgress,
    cfiProvider,
}) => {
    const sectionIndex = normalizedSectionIndex(index, sectionCount)
    const progress = sectionProgress?.getProgress(sectionIndex, fraction, size) ?? {}
    const tocItem = tocProgress?.getProgress(sectionIndex, range)
    const pageItem = pageProgress?.getProgress(sectionIndex, range)
    const cfi = cfiProvider?.getCFI(sectionIndex, range)
    return {
        ...progress,
        index: sectionIndex,
        sectionIndex,
        tocItem,
        pageItem,
        cfi,
        range,
        reason,
        pageTurnDirection,
    }
}
