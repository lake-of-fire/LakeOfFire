const normalizedWritingMode = value => {
    const mode = String(value ?? '').trim().toLowerCase()
    return mode === 'vertical-rl'
        || mode === 'vertical-lr'
        || mode === 'horizontal-tb'
        ? mode
        : null
}

const normalizedAxis = value => {
    const axis = String(value ?? '').trim().toLowerCase()
    return axis === 'vertical' || axis === 'horizontal' ? axis : null
}

const normalizedDirection = value => {
    const direction = String(value ?? '').trim().toLowerCase()
    return direction === 'rtl' || direction === 'ltr' ? direction : null
}

const firstEvidence = candidates => {
    for (const candidate of candidates) {
        const value = candidate.normalize(candidate.value)
        if (value) return { ...candidate, value }
    }
    return null
}

const explicitAxisEvidenceForInputs = inputs => firstEvidence([
    { value: inputs?.bodyDirection, source: 'attribute', normalize: normalizedAxis },
    { value: inputs?.rootDirection, source: 'attribute', normalize: normalizedAxis },
    { value: inputs?.bodyFoliateDirection, source: 'attribute', normalize: normalizedAxis },
    { value: inputs?.rootFoliateDirection, source: 'attribute', normalize: normalizedAxis },
])

const explicitWritingModeEvidenceForInputs = inputs => firstEvidence([
    { value: inputs?.bodyFoliateWritingMode, source: 'attribute-mode', normalize: normalizedWritingMode },
    { value: inputs?.rootFoliateWritingMode, source: 'attribute-mode', normalize: normalizedWritingMode },
])

const explicitClassEvidenceForInputs = inputs => {
    if (
        inputs?.bodyHasVerticalClass
        || inputs?.rootHasVerticalClass
        || inputs?.bodyHasVrtlClass
        || inputs?.rootHasVrtlClass
    ) {
        return { writingMode: 'vertical-rl', source: 'class' }
    }
    if (inputs?.bodyHasHltrClass || inputs?.rootHasHltrClass) {
        return { writingMode: 'horizontal-tb', source: 'class' }
    }
    return null
}

const writingDirectionResult = ({
    writingMode,
    direction = null,
    source,
    inputs = null,
}) => {
    const mode = normalizedWritingMode(writingMode)
    if (!mode) return null
    const normalizedCSSDirection = normalizedDirection(direction)
    const vertical = mode === 'vertical-rl' || mode === 'vertical-lr'
    return {
        vertical,
        verticalRTL: mode === 'vertical-rl',
        rtl: normalizedDirection(inputs?.bodyTextDirection) === 'rtl'
            || normalizedDirection(inputs?.rootTextDirection) === 'rtl'
            || normalizedCSSDirection === 'rtl',
        writingMode: mode,
        direction: normalizedCSSDirection,
        source,
    }
}

export const writingDirectionInputsForDocument = doc => {
    const body = doc?.body
    const documentElement = doc?.documentElement
    if (!body || !documentElement) return null
    const bootstrapText = doc.getElementById?.('mnb-writing-direction-bootstrap')?.textContent ?? ''
    const bodyStyle = body.getAttribute('style') ?? ''
    const rootStyle = documentElement.getAttribute('style') ?? ''
    const bodyFoliateDirection = body.getAttribute('data-mnb-foliate-writing-direction') ?? null
    const bodyFoliateWritingMode = body.getAttribute('data-mnb-foliate-writing-mode') ?? null
    return {
        href: doc.location?.href ?? null,
        bodyDirection: body.getAttribute('data-mnb-writing-direction') ?? null,
        rootDirection: documentElement.getAttribute('data-mnb-writing-direction') ?? null,
        bodyFoliateDirection,
        rootFoliateDirection: documentElement.getAttribute('data-mnb-foliate-writing-direction') ?? null,
        bodyFoliateWritingMode,
        rootFoliateWritingMode: documentElement.getAttribute('data-mnb-foliate-writing-mode') ?? null,
        bodyHasVerticalClass: body.classList?.contains?.('reader-vertical-writing') === true,
        rootHasVerticalClass: documentElement.classList?.contains?.('reader-vertical-writing') === true,
        bodyHasVrtlClass: body.classList?.contains?.('vrtl') === true,
        rootHasVrtlClass: documentElement.classList?.contains?.('vrtl') === true,
        bodyHasHltrClass: body.classList?.contains?.('hltr') === true,
        rootHasHltrClass: documentElement.classList?.contains?.('hltr') === true,
        bodyTextDirection: body.getAttribute('dir') ?? body.dir ?? null,
        rootTextDirection: documentElement.getAttribute('dir') ?? documentElement.dir ?? null,
        foliateDirection: bodyFoliateDirection,
        foliateWritingMode: bodyFoliateWritingMode,
        bodyStyleWritingMode: bodyStyle.match(/writing-mode\s*:\s*([^;]+)/i)?.[1]?.trim?.() ?? null,
        rootStyleWritingMode: rootStyle.match(/writing-mode\s*:\s*([^;]+)/i)?.[1]?.trim?.() ?? null,
        bootstrapWritingMode: bootstrapText.match(/writing-mode\s*:\s*([^;]+)/i)?.[1]?.trim?.() ?? null,
    }
}

export const documentHasLocalWritingDirectionSignal = doc => {
    const inputs = writingDirectionInputsForDocument(doc)
    if (!inputs) return true
    return !!(
        inputs.bodyDirection
        || inputs.rootDirection
        || inputs.foliateDirection
        || inputs.rootFoliateDirection
        || inputs.foliateWritingMode
        || inputs.rootFoliateWritingMode
        || inputs.bodyHasVerticalClass
        || inputs.rootHasVerticalClass
        || inputs.bodyHasVrtlClass
        || inputs.rootHasVrtlClass
        || inputs.bodyHasHltrClass
        || inputs.rootHasHltrClass
        || inputs.bodyStyleWritingMode
        || inputs.rootStyleWritingMode
        || inputs.bootstrapWritingMode
    )
}

export const applyObservedWritingDirectionToDocument = (
    doc,
    observed = globalThis,
) => {
    const body = doc?.body
    const documentElement = doc?.documentElement
    if (!body?.dataset || !documentElement) return false
    if (documentHasLocalWritingDirectionSignal(doc)) return false
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

export const writingDirectionFromDocumentEvidence = (
    doc,
    {
        computedWritingMode = null,
        computedDirection = null,
    } = {},
) => {
    const inputs = writingDirectionInputsForDocument(doc)
    if (!inputs) return null

    const modeEvidence = explicitWritingModeEvidenceForInputs(inputs)
    if (modeEvidence) {
        return writingDirectionResult({
            writingMode: modeEvidence.value,
            direction: computedDirection,
            source: modeEvidence.source,
            inputs,
        })
    }

    const axisEvidence = explicitAxisEvidenceForInputs(inputs)
    if (axisEvidence) {
        return writingDirectionResult({
            writingMode: axisEvidence.value === 'vertical' ? 'vertical-rl' : 'horizontal-tb',
            direction: computedDirection,
            source: axisEvidence.source,
            inputs,
        })
    }

    const classEvidence = explicitClassEvidenceForInputs(inputs)
    if (classEvidence) {
        return writingDirectionResult({
            ...classEvidence,
            direction: computedDirection,
            inputs,
        })
    }

    const computedMode = normalizedWritingMode(computedWritingMode)
    return writingDirectionResult({
        writingMode: computedMode ?? 'horizontal-tb',
        direction: computedDirection,
        source: computedMode ? 'computed' : 'computed-default',
        inputs,
    })
}
