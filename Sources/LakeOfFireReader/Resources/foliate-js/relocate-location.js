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
    // Keep raw page coordinates separate from clamped page-end completion.
    // These values alone do not prove navigation ownership or settlement.
    const firstPageGeometrySource = Number.isSafeInteger(index)
        && index >= 0 && index < sectionCount
        && Number.isFinite(fraction) && fraction >= 0 && fraction <= 1
        && Number.isFinite(size) && size > 0 && size <= 1
        ? Object.freeze({ sectionIndex: index, fractionInSection: fraction, pageFraction: size })
        : null
    return {
        ...progress,
        ...(firstPageGeometrySource ? { firstPageGeometrySource } : {}),
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
