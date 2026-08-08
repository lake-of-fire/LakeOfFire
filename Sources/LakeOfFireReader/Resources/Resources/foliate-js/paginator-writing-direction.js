export const writingDirectionInputsForDocument = (
    doc,
    observed = globalThis,
) => {
    const body = doc?.body
    const documentElement = doc?.documentElement
    if (!body || !documentElement) return null
    const bootstrapText = doc.getElementById?.('mnb-writing-direction-bootstrap')?.textContent ?? ''
    const bodyStyle = body.getAttribute('style') ?? ''
    const rootStyle = documentElement.getAttribute('style') ?? ''
    return {
        href: doc.location?.href ?? null,
        bodyDirection: body.getAttribute('data-mnb-writing-direction') ?? null,
        foliateDirection: body.getAttribute('data-mnb-foliate-writing-direction') ?? null,
        foliateWritingMode: body.getAttribute('data-mnb-foliate-writing-mode') ?? null,
        bodyHasVerticalClass: body.classList?.contains?.('reader-vertical-writing') === true,
        rootHasVrtlClass: documentElement.classList?.contains?.('vrtl') === true,
        bodyStyleWritingMode: bodyStyle.match(/writing-mode\s*:\s*([^;]+)/i)?.[1]?.trim?.() ?? null,
        rootStyleWritingMode: rootStyle.match(/writing-mode\s*:\s*([^;]+)/i)?.[1]?.trim?.() ?? null,
        bootstrapWritingMode: bootstrapText.match(/writing-mode\s*:\s*([^;]+)/i)?.[1]?.trim?.() ?? null,
        observedBookWritingMode: observed.__manabiObservedBookWritingMode ?? null,
        observedBookDirection: observed.__manabiObservedBookWritingDirection ?? null,
    }
}

export const documentHasLocalWritingDirectionSignal = (doc, observed = globalThis) => {
    const inputs = writingDirectionInputsForDocument(doc, observed)
    if (!inputs) return true
    return !!(
        inputs.bodyDirection
        || inputs.foliateDirection
        || inputs.foliateWritingMode
        || inputs.bodyHasVerticalClass
        || inputs.rootHasVrtlClass
        || inputs.bodyStyleWritingMode
        || inputs.rootStyleWritingMode
        || inputs.bootstrapWritingMode
    )
}

export const applyObservedWritingDirectionToDocument = (doc, observed = globalThis) => {
    const body = doc?.body
    const documentElement = doc?.documentElement
    if (!body?.dataset || !documentElement) return false
    if (documentHasLocalWritingDirectionSignal(doc, observed)) return false
    if (observed.__manabiObservedBookWritingDirection !== 'vertical') return false
    const writingMode = observed.__manabiObservedBookWritingMode === 'vertical-lr'
        ? 'vertical-lr'
        : 'vertical-rl'
    body.dataset.mnbFoliateWritingDirection = 'vertical'
    body.dataset.mnbFoliateWritingMode = writingMode
    body.classList.add('reader-vertical-writing')
    if (writingMode === 'vertical-rl') documentElement.classList.add('vrtl')
    return true
}
