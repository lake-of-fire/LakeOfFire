import { normalizePaginatorWritingDirection } from './ebook-paginator-writing-direction.js'

export const applyEbookViewerWritingDirection = async ({
    renderer,
    value,
    onNormalized = null,
}) => {
    const writingDirection = normalizePaginatorWritingDirection(value)
    onNormalized?.(writingDirection)
    const renderResult = await renderer?.setWritingDirectionOverride?.(writingDirection)
        ?? { rendered: false, reason: 'renderer-unavailable' }
    const contents = renderer?.getContents?.() ?? []
    for (const content of contents) {
        const doc = content?.doc ?? content?.document ?? null
        try {
            doc?.defaultView?.manabiApplyVerticalWritingCheck?.()
        } catch (_error) {
            // A child presentation refresh cannot invalidate completed layout.
        }
    }
    return { writingDirection, renderResult }
}
