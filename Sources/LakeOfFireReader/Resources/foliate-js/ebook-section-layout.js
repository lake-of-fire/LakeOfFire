const CHUNK_ATOMIC_TAG_NAMES = new Set([
    'manabi-segment',
    'img',
    'picture',
    'video',
    'audio',
    'canvas',
    'svg',
    'iframe',
    'br',
    'hr',
    'input',
    'textarea',
    'select',
])

const WARMUP_DELAY_MS = 16
const WARMUP_PAGE_BATCH = 2

const logReaderPerf = (event, detail = {}) => {
    try {
        const line = `# READERPERF ${JSON.stringify({ event, ...detail })}`
        globalThis.window?.webkit?.messageHandlers?.print?.postMessage?.(line)
    } catch (_error) {}
}

const copyAttributes = (from, to) => {
    if (!(from instanceof Element) || !(to instanceof Element)) return
    for (const { name, value } of Array.from(from.attributes)) {
        to.setAttribute(name, value)
    }
}

const resolveSectionRoot = doc => {
    const readerContent = doc?.getElementById?.('reader-content')
    if (!(readerContent instanceof HTMLElement)) return null
    const pageNode = readerContent.querySelector(':scope > .page') || readerContent
    return pageNode.querySelector('article') || pageNode
}

const isRangeLike = value => {
    if (!value || typeof value !== 'object') return false
    return value.startContainer != null
        && value.endContainer != null
        && typeof value.collapsed === 'boolean'
}

const shouldSkipChunkSourceNode = node => {
    if (!(node instanceof Element)) return false
    return node.matches?.(
        '.manabi-tracking-container,' +
        '.manabi-tracking-button,' +
        '.manabi-tracking-status-unlock-button-container,' +
        '.manabi-tracking-status-tip,' +
        '#manabi-tracking-section-subscription-preview-inline-notice,' +
        '#manabi-tracking-footer,' +
        '.manabi-article-marked-as-finished'
    ) === true
}

const shouldKeepChunkTextNode = textNode => {
    if (textNode?.nodeType !== Node.TEXT_NODE) return false
    const value = textNode.nodeValue || ''
    if (value.length === 0) return false
    if (value.trim() !== '') return true
    const parentElement = textNode.parentElement
    if (!(parentElement instanceof HTMLElement)) return false
    const display = parentElement.ownerDocument?.defaultView?.getComputedStyle?.(parentElement)?.display || ''
    if (display.startsWith('inline')) return true
    return parentElement.matches?.(
        'span, ruby, rb, rt, rp, em, strong, b, i, small, sub, sup, mark, code, a, manabi-sentence'
    ) === true
}

const chunkAncestorChainForNode = (node, rootNode) => {
    const chain = []
    let current = node
    while (current && current !== rootNode) {
        if (current.nodeType === Node.ELEMENT_NODE && !shouldSkipChunkSourceNode(current)) {
            chain.unshift(current)
        }
        current = current.parentNode
    }
    return chain
}

const cloneChunkShell = sourceElement => {
    const clone = sourceElement.cloneNode(false)
    if (clone instanceof Element) {
        clone.removeAttribute('id')
        clone.removeAttribute('data-manabi-tracking-section-read')
        if (clone.classList.contains('manabi-tracking-section') && clone.dataset.manabiTrackingSectionKind !== 'title') {
            clone.classList.remove('manabi-tracking-section')
            clone.classList.add('manabi-semantic-section')
        }
    }
    return clone
}

const cloneChunkUnitNode = (unit, targetDocument) => {
    if (unit.type === 'text') {
        return targetDocument.createTextNode(unit.textContent ?? unit.sourceNode.nodeValue ?? '')
    }
    const clone = unit.sourceNode.cloneNode(true)
    if (clone instanceof Element && unit.kind !== 'segment') {
        clone.removeAttribute('id')
    }
    return clone
}

const collectEbookChunkUnits = rootNode => {
    const units = []

    const visit = node => {
        if (!node) return
        if (node.nodeType === Node.TEXT_NODE) {
            if (shouldKeepChunkTextNode(node)) {
                const textContent = node.nodeValue || ''
                units.push({
                    type: 'text',
                    kind: 'text',
                    sourceNode: node,
                    ancestors: chunkAncestorChainForNode(node.parentNode, rootNode),
                    textContent,
                    sourceStartOffset: 0,
                    sourceEndOffset: textContent.length,
                })
            }
            return
        }
        if (node.nodeType !== Node.ELEMENT_NODE) return
        if (shouldSkipChunkSourceNode(node)) return
        const tagName = node.tagName?.toLowerCase?.() || ''
        if (CHUNK_ATOMIC_TAG_NAMES.has(tagName) || node.dataset?.manabiChunkAtomic === 'true') {
            units.push({
                type: 'element',
                kind: tagName === 'manabi-segment' ? 'segment' : 'atomic',
                sourceNode: node,
                ancestors: chunkAncestorChainForNode(node.parentNode, rootNode),
            })
            return
        }
        if (!node.firstChild) {
            units.push({
                type: 'element',
                kind: 'leaf',
                sourceNode: node,
                ancestors: chunkAncestorChainForNode(node.parentNode, rootNode),
            })
            return
        }
        for (const childNode of Array.from(node.childNodes)) {
            visit(childNode)
        }
    }

    for (const childNode of Array.from(rootNode.childNodes)) {
        visit(childNode)
    }
    return units
}

const createChunkAppendState = () => ({
    sourceAncestors: [],
    destinationAncestors: [],
    unitCount: 0,
})

const resolveChunkTextSplitIndex = textContent => {
    const scalars = Array.from(textContent || '')
    if (scalars.length < 2) return 0
    const midpoint = Math.floor(scalars.length / 2)
    for (let offset = 0; offset < scalars.length; offset += 1) {
        const forwardIndex = midpoint + offset
        if (forwardIndex > 0 && forwardIndex < scalars.length && /\s/.test(scalars[forwardIndex])) {
            return forwardIndex
        }
        const backwardIndex = midpoint - offset
        if (backwardIndex > 0 && backwardIndex < scalars.length && /\s/.test(scalars[backwardIndex])) {
            return backwardIndex
        }
    }
    return midpoint
}

const splitChunkUnitForFit = unit => {
    if (!unit || unit.type !== 'text') return null
    const textContent = unit.textContent ?? unit.sourceNode?.nodeValue ?? ''
    if (textContent.length < 2) return null
    const scalars = Array.from(textContent)
    const splitIndex = resolveChunkTextSplitIndex(textContent)
    if (splitIndex <= 0 || splitIndex >= scalars.length) return null
    const leftText = scalars.slice(0, splitIndex).join('')
    const rightText = scalars.slice(splitIndex).join('')
    if (!leftText.length || !rightText.length) return null
    const leftLength = leftText.length
    return [
        {
            ...unit,
            textContent: leftText,
            sourceStartOffset: unit.sourceStartOffset,
            sourceEndOffset: unit.sourceStartOffset + leftLength,
        },
        {
            ...unit,
            textContent: rightText,
            sourceStartOffset: unit.sourceStartOffset + leftLength,
            sourceEndOffset: unit.sourceEndOffset,
        },
    ]
}

const appendChunkUnit = (chunkBody, appendState, unit) => {
    const ancestors = Array.isArray(unit.ancestors) ? unit.ancestors : []
    let commonPrefixLength = 0
    while (
        commonPrefixLength < appendState.sourceAncestors.length &&
        commonPrefixLength < ancestors.length &&
        appendState.sourceAncestors[commonPrefixLength] === ancestors[commonPrefixLength]
    ) {
        commonPrefixLength += 1
    }

    appendState.sourceAncestors.length = commonPrefixLength
    appendState.destinationAncestors.length = commonPrefixLength

    let parent = commonPrefixLength > 0
        ? appendState.destinationAncestors[commonPrefixLength - 1]
        : chunkBody
    for (let index = commonPrefixLength; index < ancestors.length; index += 1) {
        const shellClone = cloneChunkShell(ancestors[index])
        parent.appendChild(shellClone)
        appendState.sourceAncestors.push(ancestors[index])
        appendState.destinationAncestors.push(shellClone)
        parent = shellClone
    }

    const leafParent = appendState.destinationAncestors.length > 0
        ? appendState.destinationAncestors[appendState.destinationAncestors.length - 1]
        : chunkBody
    const leafNode = cloneChunkUnitNode(unit, chunkBody.ownerDocument)
    leafParent.appendChild(leafNode)
    appendState.unitCount += 1

    return {
        commonPrefixLength,
        leafNode,
    }
}

const revertChunkUnit = (appendState, appendRecord) => {
    appendRecord?.leafNode?.remove?.()
    appendState.unitCount = Math.max(0, appendState.unitCount - 1)
    while (appendState.destinationAncestors.length > appendRecord.commonPrefixLength) {
        const shellClone = appendState.destinationAncestors.pop()
        appendState.sourceAncestors.pop()
        if (shellClone?.childNodes?.length === 0) {
            shellClone.remove()
        }
    }
}

const chunkBodyHasOverflow = (chunkBody, vertical) => {
    if (!(chunkBody instanceof HTMLElement)) return false
    const slack = 1
    return vertical
        ? chunkBody.scrollWidth > chunkBody.clientWidth + slack
        : chunkBody.scrollHeight > chunkBody.clientHeight + slack
}

const allowOversizeChunkOverflow = (chunkNode, chunkBody) => {
    if (!(chunkNode instanceof HTMLElement) || !(chunkBody instanceof HTMLElement)) return
    chunkNode.classList.add('manabi-page-column-chunk-oversize')
    chunkNode.dataset.manabiChunkOversize = 'true'
    chunkBody.style.overflow = 'visible'
    chunkNode.style.overflow = 'visible'
}

const createChunkSection = ({ doc, pageNode, pageIndex, columnIndex, layoutVersion, runtime }) => {
    const chunkNode = doc.createElement('section')
    chunkNode.className = 'manabi-tracking-section manabi-page-column-chunk'
    chunkNode.dataset.manabiTrackingOrigin = 'js'
    chunkNode.dataset.manabiTrackingSectionKind = 'chunk'
    chunkNode.dataset.manabiPageIndex = String(pageIndex)
    chunkNode.dataset.manabiColumnIndex = String(columnIndex)
    chunkNode.dataset.manabiChunkId = `chunk-v${layoutVersion}-p${pageIndex}-c${columnIndex}`
    chunkNode.dataset.manabiTrackingSectionId = chunkNode.dataset.manabiChunkId
    const chunkBody = doc.createElement('div')
    chunkBody.className = 'manabi-page-column-body'
    chunkNode.appendChild(chunkBody)
    pageNode.appendChild(chunkNode)
    runtime?.manabiCreateTrackingSectionChrome?.(chunkNode, columnIndex, {
        includePreviewUI: false,
    })
    return { chunkNode, chunkBody }
}

export class EbookSectionLayout {
    #doc = null
    #root = null
    #normalizedRootHTML = null
    #sourceDoc = null
    #sourceRoot = null
    #layoutVersion = 0
    #pageRecords = []
    #unitRecords = []
    #unitIndicesBySourceNode = new Map()
    #controller = null
    #currentSourceAnchor = null
    #buildState = null
    #warmupTimer = null
    #warmupToken = 0

    attach(doc) {
        if (this.#doc === doc) return
        this.destroy()
        this.#doc = doc
        this.#root = resolveSectionRoot(doc)
        if (doc?.defaultView) {
            this.#controller = {
                ensureSourceDocument: () => {
                    try {
                        return this.ensureSourceDocument()
                    } catch (error) {
                        console.error(error)
                        return null
                    }
                },
                pageCount: () => this.pageCount(),
                hasPendingWarmup: () => this.hasPendingWarmup(),
                ensurePageBuilt: (pageIndex, options) => this.ensurePageBuilt(pageIndex, options),
                visibleSourceRange: pageIndex => this.visibleSourceRange(pageIndex),
                captureLocationForPage: pageIndex => this.captureLocationForPage(pageIndex),
                pageIndexForLocation: location => this.pageIndexForLocation(location),
                sourceRangeForLocation: location => this.sourceRangeForLocation(location),
                requestRebuild: ({ reason, anchor } = {}) => {
                    try {
                        return this.buildFromAnchor(anchor ?? this.#currentSourceAnchor ?? 0, {
                            reason: reason ?? 'requestRebuild',
                        })
                    } catch (error) {
                        console.error(error)
                        return null
                    }
                },
                rebuildFromCurrentLocation: ({ reason } = {}) => {
                    try {
                        return this.rebuildFromCurrentLocation({
                            reason: reason ?? 'rebuildFromCurrentLocation',
                        })
                    } catch (error) {
                        console.error(error)
                        return null
                    }
                },
            }
            doc.defaultView.manabiEbookSectionLayoutController = this.#controller
        }
    }

    destroy() {
        this.#cancelWarmup()
        if (this.#doc?.defaultView?.manabiEbookSectionLayoutController === this.#controller) {
            delete this.#doc.defaultView.manabiEbookSectionLayoutController
        }
        this.#doc = null
        this.#root = null
        this.#normalizedRootHTML = null
        this.#sourceDoc = null
        this.#sourceRoot = null
        this.#layoutVersion = 0
        this.#pageRecords = []
        this.#unitRecords = []
        this.#unitIndicesBySourceNode = new Map()
        this.#controller = null
        this.#currentSourceAnchor = null
        this.#buildState = null
    }

    getSourceDocument() {
        return this.#sourceDoc
    }

    ensureSourceDocument() {
        const doc = this.#doc
        const runtime = doc?.defaultView
        const root = this.#root
        if (!(doc instanceof Document) || !(root instanceof HTMLElement)) return null
        if (doc.body?.dataset?.isEbook !== 'true') return null
        return this.#runWithSuppressedMutations(() => {
            this.#prepareSourceSnapshot({ doc, runtime, root })
            return this.#sourceDoc
        })
    }

    setCurrentSourceAnchor(anchor) {
        if (!anchor) return null
        this.#currentSourceAnchor = anchor
        return anchor
    }

    getCurrentSourceAnchor() {
        return this.#currentSourceAnchor
    }

    invalidate({ reason = 'unknown' } = {}) {
        return this.rebuildFromCurrentLocation({ reason })
    }

    build({ reason = 'unknown', anchor = this.#currentSourceAnchor ?? 0, anchorResolver = null, location = null } = {}) {
        return this.buildFromAnchor(anchor, { reason, anchorResolver, location })
    }

    buildFromAnchor(anchor, { reason = 'unknown', anchorResolver = null, location = null } = {}) {
        const doc = this.#doc
        const runtime = doc?.defaultView
        const root = this.#root
        if (!(doc instanceof Document) || !(root instanceof HTMLElement)) return null
        if (doc.body?.dataset?.isEbook !== 'true') return null

        let result = null
        this.#runWithSuppressedMutations(() => {
            this.#cancelWarmup()
            doc.documentElement.dataset.manabiLayoutComplete = 'false'

            const units = this.#prepareSourceSnapshot({ doc, runtime, root })
            if (!units?.length) {
                root.innerHTML = ''
                root.classList.add('manabi-page-root')
                this.#pageRecords = []
                this.#buildState = null
                this.#refreshLiveRoot({ runtime, root, complete: true })
                result = {
                    pageCount: 0,
                    reason,
                    layoutComplete: true,
                }
                return
            }

            const metrics = runtime?.manabiGetChunkLayoutMetrics?.({ isEbook: true }) || {
                vertical: doc.body?.classList?.contains?.('reader-vertical-writing') === true,
                columnCount: 1,
            }
            const columnCount = Math.max(1, Number.parseInt(String(metrics.columnCount || 1), 10) || 1)
            this.#layoutVersion += 1
            doc.documentElement.dataset.manabiLayoutVersion = String(this.#layoutVersion)
            const resolvedAnchor = typeof anchorResolver === 'function'
                ? (anchorResolver(this.#sourceDoc || doc) ?? anchorResolver(doc))
                : anchor
            const targetUnitIndex = this.#resolveTargetUnitIndexFromLocationOrAnchor(location, resolvedAnchor)
            const targetSourceLocation = this.#sourceLocationForUnitIndex(targetUnitIndex)
            logReaderPerf('ebook-layout-build-target', {
                reason,
                targetUnitIndex,
                anchorSentenceIdentifier: this.#sentenceIdentifierForAnchor(resolvedAnchor),
                targetSentenceIdentifier: this.#sentenceIdentifierForUnitIndex(targetUnitIndex),
                locationAnchorUnitIndex: location?.anchorUnitIndex ?? null,
                locationAnchorSentenceIdentifier: location?.anchorSentenceIdentifier ?? null,
            })

            this.#buildState = this.#createBuildState({
                doc,
                runtime,
                root,
                metrics,
                columnCount,
                units,
                layoutVersion: this.#layoutVersion,
                targetUnitIndex,
                targetSourceLocation,
            })
            this.#continueBuilding()

            const fallbackPageIndex = Math.max(0, this.#unitRecords[targetUnitIndex]?.pageIndex ?? 0)
            this.#currentSourceAnchor = this.#sourceAnchorForLocation(targetSourceLocation)
                || this.#sourceAnchorForUnitIndex(targetUnitIndex)
                || this.#normalizeSourceAnchor(resolvedAnchor, fallbackPageIndex)
            logReaderPerf('ebook-layout-current-anchor', {
                reason,
                fallbackPageIndex,
                currentSentenceIdentifier: this.#sentenceIdentifierForAnchor(this.#currentSourceAnchor),
            })
            this.#refreshLiveRoot({
                runtime,
                root,
                complete: this.isLayoutComplete(),
            })
            if (!this.isLayoutComplete()) {
                this.#scheduleWarmup()
            }

            result = {
                pageCount: this.pageCount(),
                reason,
                layoutComplete: this.isLayoutComplete(),
            }
        })
        return result
    }

    rebuildFromCurrentLocation({ reason = 'unknown' } = {}) {
        const currentPageIndex = this.pageIndexForAnchor(this.#currentSourceAnchor)
        const location = currentPageIndex != null
            ? this.captureLocationForPage(currentPageIndex)
            : null
        return this.build({
            reason,
            anchor: this.#currentSourceAnchor ?? 0,
            location,
        })
    }

    pageCount() {
        return this.#effectivePageCount()
    }

    isLayoutComplete() {
        return this.#buildState == null
    }

    hasPendingWarmup() {
        return !this.isLayoutComplete()
    }

    ensurePageBuilt(pageIndex, { reason = 'ensure-page' } = {}) {
        if (!Number.isFinite(pageIndex) || pageIndex < 0) {
            return {
                pageCount: this.pageCount(),
                reason,
                layoutComplete: this.isLayoutComplete(),
            }
        }
        if (pageIndex < this.pageCount() || this.#buildState == null) {
            return {
                pageCount: this.pageCount(),
                reason,
                layoutComplete: this.isLayoutComplete(),
            }
        }

        const doc = this.#doc
        const runtime = doc?.defaultView
        const root = this.#root
        if (!(doc instanceof Document) || !(root instanceof HTMLElement)) return null

        let result = null
        this.#runWithSuppressedMutations(() => {
            if (this.#buildState) {
                this.#cancelWarmup()
                this.#buildState.stopAfterPageIndex = Math.max(
                    pageIndex,
                    this.#buildState.stopAfterPageIndex ?? -1
                )
                this.#continueBuilding()
                this.#refreshLiveRoot({
                    runtime,
                    root,
                    complete: this.isLayoutComplete(),
                })
                if (!this.isLayoutComplete()) {
                    this.#scheduleWarmup()
                }
            }
            result = {
                pageCount: this.pageCount(),
                reason,
                layoutComplete: this.isLayoutComplete(),
            }
        })
        return result
    }

    sourceRangeForPage(pageIndex) {
        return this.sourceRangeForLocation(this.captureLocationForPage(pageIndex))
    }

    captureLocationForPage(pageIndex) {
        const pageRecord = this.#pageRecords[pageIndex]
        if (!pageRecord || pageRecord.startUnitIndex == null || pageRecord.endUnitIndex == null) return null
        let anchorUnitIndex = pageRecord.startUnitIndex
        const currentAnchorUnitIndex = this.#sourceUnitIndexForAnchor(this.#currentSourceAnchor)
        if (Number.isFinite(currentAnchorUnitIndex)
            && currentAnchorUnitIndex >= pageRecord.startUnitIndex
            && currentAnchorUnitIndex <= pageRecord.endUnitIndex) {
            anchorUnitIndex = currentAnchorUnitIndex
        }
        return {
            pageIndex,
            startUnitIndex: pageRecord.startUnitIndex,
            endUnitIndex: pageRecord.endUnitIndex,
            anchorUnitIndex,
            anchorSentenceIdentifier: this.#sentenceIdentifierForUnitIndex(anchorUnitIndex),
            layoutVersion: this.#layoutVersion,
        }
    }

    pageIndexForLocation(location) {
        const anchorUnitIndex = location?.anchorUnitIndex
        if (!Number.isFinite(anchorUnitIndex)) return null
        return this.#unitRecords[anchorUnitIndex]?.pageIndex ?? null
    }

    sourceRangeForLocation(location) {
        const startUnitIndex = location?.startUnitIndex
        const endUnitIndex = location?.endUnitIndex
        if (!Number.isFinite(startUnitIndex) || !Number.isFinite(endUnitIndex)) return null
        const startUnit = this.#unitRecords[startUnitIndex]
        const endUnit = this.#unitRecords[endUnitIndex]
        if (!startUnit || !endUnit || !this.#sourceDoc) return null
        const range = this.#sourceDoc.createRange()
        if (startUnit.type === 'text') {
            range.setStart(startUnit.sourceNode, startUnit.sourceStartOffset)
        } else {
            range.setStartBefore(startUnit.sourceNode)
        }
        if (endUnit.type === 'text') {
            range.setEnd(endUnit.sourceNode, endUnit.sourceEndOffset)
        } else {
            range.setEndAfter(endUnit.sourceNode)
        }
        return range
    }

    visibleSourceRange(pageIndex) {
        return this.sourceRangeForLocation(this.captureLocationForPage(pageIndex))
    }

    pageIndexForAnchor(anchor) {
        if (typeof anchor === 'number') {
            const count = this.pageCount()
            if (count <= 1) return 0
            return Math.max(0, Math.min(count - 1, Math.round(anchor * (count - 1))))
        }
        if (!anchor) return 0
        const index = this.#sourceUnitIndexForAnchor(anchor)
        return index != null ? (this.#unitRecords[index]?.pageIndex ?? 0) : null
    }

    getChunkIdForPage(pageIndex, columnIndex = 0) {
        const pageRecord = this.#pageRecords[pageIndex]
        if (!pageRecord) return null
        const chunkRecord = pageRecord.chunkRecords.find(record => record.columnIndex === columnIndex)
            || pageRecord.chunkRecords[0]
        return chunkRecord?.chunkId ?? null
    }

    #effectivePageCount() {
        if (this.#pageRecords.length === 0) return 0
        const lastPageRecord = this.#pageRecords[this.#pageRecords.length - 1]
        const hasOnlyEmptyChunks = lastPageRecord?.chunkRecords?.length > 0
            && lastPageRecord.chunkRecords.every(record => record.startUnitIndex == null)
        if (hasOnlyEmptyChunks && this.#buildState) {
            return Math.max(0, this.#pageRecords.length - 1)
        }
        return this.#pageRecords.length
    }

    #runWithSuppressedMutations(callback) {
        const suppressMutations = this.#doc?.defaultView?.manabiWithTrackingStructureMutationSuppressed
            || (fn => fn())
        return suppressMutations(callback)
    }

    #prepareSourceSnapshot({ doc, runtime, root }) {
        if (this.#normalizedRootHTML == null) {
            this.#normalizedRootHTML = root.innerHTML
            root.innerHTML = this.#normalizedRootHTML
            runtime?.manabiNormalizeLegacyTrackingStructure?.(doc)
            runtime?.manabiBuildSentenceArchive?.(doc)
            this.#normalizedRootHTML = root.innerHTML
            this.#sourceDoc = null
            this.#sourceRoot = null
        } else {
            root.innerHTML = this.#normalizedRootHTML
            runtime?.manabiBuildSentenceArchive?.(doc)
        }

        if (!(this.#sourceDoc instanceof Document) || !(this.#sourceRoot instanceof HTMLElement)) {
            this.#sourceDoc = doc.implementation.createHTMLDocument('')
            copyAttributes(doc.documentElement, this.#sourceDoc.documentElement)
            copyAttributes(doc.body, this.#sourceDoc.body)
            this.#sourceDoc.body.className = doc.body.className
            this.#sourceDoc.body.innerHTML = doc.body.innerHTML
            this.#sourceRoot = resolveSectionRoot(this.#sourceDoc)
        }

        if (!(this.#sourceRoot instanceof HTMLElement)) {
            this.#unitRecords = []
            this.#unitIndicesBySourceNode = new Map()
            return []
        }

        this.#unitRecords = collectEbookChunkUnits(this.#sourceRoot)
        this.#refreshUnitIndexMap()
        return this.#unitRecords
    }

    #refreshUnitIndexMap() {
        this.#unitIndicesBySourceNode = new Map()
        this.#unitRecords.forEach((unit, index) => {
            const indices = this.#unitIndicesBySourceNode.get(unit.sourceNode) || []
            indices.push(index)
            this.#unitIndicesBySourceNode.set(unit.sourceNode, indices)
        })
    }

    #sourceUnitIndexForAnchor(anchor) {
        const unitCount = this.#unitRecords.length
        if (unitCount <= 1) return unitCount === 0 ? null : 0
        if (typeof anchor === 'number') {
            return Math.max(0, Math.min(unitCount - 1, Math.round(anchor * (unitCount - 1))))
        }
        if (!anchor) return null
        if (isRangeLike(anchor)) {
            const directIndex = this.#unitIndexForAnchorNode(anchor.startContainer, anchor.startOffset)
            if (directIndex != null) return directIndex
            const sentenceIdentifier = this.#sentenceIdentifierForNode(anchor.startContainer)
            return sentenceIdentifier ? this.#unitIndexForSentenceIdentifier(sentenceIdentifier) : null
        }
        const directIndex = this.#unitIndexForAnchorNode(anchor, 0)
        if (directIndex != null) return directIndex
        const sentenceIdentifier = this.#sentenceIdentifierForNode(anchor)
        return sentenceIdentifier ? this.#unitIndexForSentenceIdentifier(sentenceIdentifier) : null
    }

    #resolveTargetUnitIndex(anchor) {
        const unitCount = this.#unitRecords.length
        if (unitCount <= 1) return 0
        return this.#sourceUnitIndexForAnchor(anchor) ?? 0
    }

    #resolveTargetUnitIndexFromLocationOrAnchor(location, anchor) {
        const anchorUnitIndex = this.#sourceUnitIndexForAnchor(anchor)
        const anchorSentenceIdentifier = this.#sentenceIdentifierForAnchor(anchor)
        if (Number.isFinite(anchorUnitIndex)) {
            const startUnitIndex = location?.startUnitIndex
            const endUnitIndex = location?.endUnitIndex
            if (!Number.isFinite(startUnitIndex)
                || !Number.isFinite(endUnitIndex)
                || (anchorUnitIndex >= startUnitIndex && anchorUnitIndex <= endUnitIndex)) {
                return Math.max(0, Math.min(this.#unitRecords.length - 1, anchorUnitIndex))
            }
        }
        const locationAnchorUnitIndex = location?.anchorUnitIndex
        const locationSentenceIdentifier = location?.anchorSentenceIdentifier
        const locationAnchorIsInRange = Number.isFinite(locationAnchorUnitIndex)
            && locationAnchorUnitIndex >= 0
            && locationAnchorUnitIndex < this.#unitRecords.length
        const locationMatchesAnchorSentence = !anchorSentenceIdentifier
            || !locationSentenceIdentifier
            || locationSentenceIdentifier === anchorSentenceIdentifier
            || this.#sentenceIdentifierForUnitIndex(locationAnchorUnitIndex) === anchorSentenceIdentifier
        if (locationAnchorIsInRange && locationMatchesAnchorSentence) {
            return Math.max(0, Math.min(this.#unitRecords.length - 1, locationAnchorUnitIndex))
        }
        return this.#resolveTargetUnitIndex(anchor)
    }

    #createBuildState({
        doc,
        runtime,
        root,
        metrics,
        columnCount,
        units,
        layoutVersion,
        targetUnitIndex,
        targetSourceLocation,
    }) {
        root.innerHTML = ''
        root.classList.add('manabi-page-root')
        root.dataset.manabiLayoutVersion = String(layoutVersion)
        this.#pageRecords = []

        const pageNode = doc.createElement('div')
        pageNode.className = 'manabi-page'
        pageNode.dataset.manabiPageIndex = '0'
        root.appendChild(pageNode)

        const pageRecord = {
            pageIndex: 0,
            pageNode,
            startUnitIndex: null,
            endUnitIndex: null,
            chunkRecords: [],
        }
        this.#pageRecords.push(pageRecord)

        const { chunkNode, chunkBody } = createChunkSection({
            doc,
            pageNode,
            pageIndex: 0,
            columnIndex: 0,
            layoutVersion,
            runtime,
        })
        const chunkRecord = {
            pageIndex: 0,
            columnIndex: 0,
            chunkId: chunkNode.dataset.manabiChunkId,
            chunkNode,
            startUnitIndex: null,
            endUnitIndex: null,
        }
        pageRecord.chunkRecords.push(chunkRecord)

        return {
            doc,
            runtime,
            root,
            metrics,
            columnCount,
            units,
            layoutVersion,
            targetUnitIndex,
            targetSourceLocation,
            stopAfterPageIndex: null,
            unitIndex: 0,
            pageIndex: 0,
            columnIndex: 0,
            pageNode,
            pageRecord,
            chunkNode,
            chunkBody,
            chunkRecord,
            appendState: createChunkAppendState(),
        }
    }

    #assignUnitToCurrentChunk(state, unitIndex) {
        const unit = state.units[unitIndex]
        unit.pageIndex = state.pageIndex
        unit.columnIndex = state.columnIndex
        unit.chunkId = state.chunkRecord.chunkId
        if (state.pageRecord.startUnitIndex == null) state.pageRecord.startUnitIndex = unitIndex
        state.pageRecord.endUnitIndex = unitIndex
        if (state.chunkRecord.startUnitIndex == null) state.chunkRecord.startUnitIndex = unitIndex
        state.chunkRecord.endUnitIndex = unitIndex
        if (
            state.stopAfterPageIndex == null
            && (
                this.#unitContainsSourceLocation(unit, state.targetSourceLocation)
                || unitIndex === state.targetUnitIndex
            )
        ) {
            state.stopAfterPageIndex = state.pageIndex
        }
    }

    #advanceChunk(state) {
        state.columnIndex += 1
        if (state.columnIndex >= state.columnCount) {
            state.pageIndex += 1
            state.columnIndex = 0
            state.pageNode = state.doc.createElement('div')
            state.pageNode.className = 'manabi-page'
            state.pageNode.dataset.manabiPageIndex = String(state.pageIndex)
            state.root.appendChild(state.pageNode)
            state.pageRecord = {
                pageIndex: state.pageIndex,
                pageNode: state.pageNode,
                startUnitIndex: null,
                endUnitIndex: null,
                chunkRecords: [],
            }
            this.#pageRecords.push(state.pageRecord)
        }
        const next = createChunkSection({
            doc: state.doc,
            pageNode: state.pageNode,
            pageIndex: state.pageIndex,
            columnIndex: state.columnIndex,
            layoutVersion: state.layoutVersion,
            runtime: state.runtime,
        })
        state.chunkNode = next.chunkNode
        state.chunkBody = next.chunkBody
        state.chunkRecord = {
            pageIndex: state.pageIndex,
            columnIndex: state.columnIndex,
            chunkId: state.chunkNode.dataset.manabiChunkId,
            chunkNode: state.chunkNode,
            startUnitIndex: null,
            endUnitIndex: null,
        }
        state.pageRecord.chunkRecords.push(state.chunkRecord)
        state.appendState = createChunkAppendState()
    }

    #continueBuilding() {
        const state = this.#buildState
        if (!state) return

        while (state.unitIndex < state.units.length) {
            if (state.stopAfterPageIndex != null && state.pageIndex > state.stopAfterPageIndex) {
                break
            }
            const unit = state.units[state.unitIndex]
            const appendRecord = appendChunkUnit(state.chunkBody, state.appendState, unit)

            if (state.appendState.unitCount <= 1) {
                if (chunkBodyHasOverflow(state.chunkBody, state.metrics.vertical)) {
                    const splitUnits = splitChunkUnitForFit(unit)
                    if (splitUnits && splitUnits.length > 1) {
                        revertChunkUnit(state.appendState, appendRecord)
                        state.units.splice(state.unitIndex, 1, ...splitUnits)
                        continue
                    }
                    allowOversizeChunkOverflow(state.chunkNode, state.chunkBody)
                }
                this.#assignUnitToCurrentChunk(state, state.unitIndex)
                state.unitIndex += 1
                continue
            }

            if (!chunkBodyHasOverflow(state.chunkBody, state.metrics.vertical)) {
                this.#assignUnitToCurrentChunk(state, state.unitIndex)
                state.unitIndex += 1
                continue
            }

            revertChunkUnit(state.appendState, appendRecord)
            const splitUnits = splitChunkUnitForFit(unit)
            if (splitUnits && splitUnits.length > 1) {
                state.units.splice(state.unitIndex, 1, ...splitUnits)
                continue
            }
            this.#advanceChunk(state)
        }

        this.#refreshUnitIndexMap()
        if (state.unitIndex >= state.units.length) {
            this.#trimTrailingEmptyPage()
            this.#buildState = null
            return
        }
        this.#buildState = state
    }

    #trimTrailingEmptyPage() {
        const lastPageRecord = this.#pageRecords[this.#pageRecords.length - 1]
        if (!lastPageRecord?.chunkRecords?.length) return
        const hasOnlyEmptyChunks = lastPageRecord.chunkRecords.every(record => record.startUnitIndex == null)
        if (!hasOnlyEmptyChunks) return
        lastPageRecord.pageNode.remove()
        this.#pageRecords.pop()
    }

    #scheduleWarmup() {
        this.#cancelWarmup()
        if (!this.#buildState || !(this.#doc?.defaultView instanceof Window)) return
        const token = ++this.#warmupToken
        logReaderPerf('ebook-layout-warmup-scheduled', {
            layoutVersion: this.#layoutVersion,
            pageCount: this.pageCount(),
        })
        this.#warmupTimer = this.#doc.defaultView.setTimeout(() => {
            this.#warmupTimer = null
            this.#warmRemainingPages(token)
        }, WARMUP_DELAY_MS)
    }

    #cancelWarmup() {
        if (this.#warmupTimer != null && this.#doc?.defaultView) {
            this.#doc.defaultView.clearTimeout(this.#warmupTimer)
        }
        this.#warmupTimer = null
        this.#warmupToken += 1
    }

    #warmRemainingPages(token) {
        if (token !== this.#warmupToken || !this.#buildState) return
        const doc = this.#doc
        const runtime = doc?.defaultView
        const root = this.#root
        if (!(doc instanceof Document) || !(root instanceof HTMLElement)) return

        this.#runWithSuppressedMutations(() => {
            if (!this.#buildState) return
            const nextVisiblePageIndex = Math.max(0, this.pageCount() + WARMUP_PAGE_BATCH - 1)
            this.#buildState.stopAfterPageIndex = Math.max(
                nextVisiblePageIndex,
                this.#buildState.stopAfterPageIndex ?? -1
            )
            this.#continueBuilding()
            this.#refreshLiveRoot({
                runtime,
                root,
                complete: this.isLayoutComplete(),
            })
            if (!this.isLayoutComplete()) {
                this.#scheduleWarmup()
            } else {
                logReaderPerf('ebook-layout-warmup-complete', {
                    layoutVersion: this.#layoutVersion,
                    pageCount: this.pageCount(),
                })
            }
        })
    }

    #refreshLiveRoot({ runtime, root, complete }) {
        runtime?.manabiEnsureTrackingFooter?.()
        runtime?.manabiEnsureTrackingMarkers?.(root)

        if (complete) {
            runtime?.manabiMarkSentenceOwnershipByTerminalSegment?.(root)
            root.querySelectorAll('.manabi-page-column-chunk').forEach(sectionNode => {
                runtime?.manabiFinalizeTrackingSectionState?.(sectionNode)
            })
            runtime?.manabiWireAllTrackingButtons?.()
            runtime?.manabi_refreshArticleReadingProgress?.()
            runtime?.manabi_refreshSectionsMarkedAsRead?.()
        } else {
            root.querySelectorAll('.manabi-page-column-chunk .manabi-tracking-button').forEach(buttonNode => {
                if (buttonNode instanceof HTMLButtonElement) {
                    buttonNode.disabled = true
                    buttonNode.setAttribute('aria-pressed', 'false')
                }
            })
        }

        try {
            runtime?.manabiTategakiText?.clear?.({ root })
            runtime?.manabiTategakiText?.apply?.({
                root,
                vertical: this.#buildState?.metrics?.vertical
                    ?? root.ownerDocument?.body?.classList?.contains?.('reader-vertical-writing') === true,
                isReaderMode: true,
                isEbook: true,
            })
        } catch (_error) {}

        if (this.#doc?.documentElement) {
            this.#doc.documentElement.dataset.manabiLayoutComplete = complete ? 'true' : 'false'
        }
        if (complete) {
            try {
                this.#doc?.defaultView?.dispatchEvent?.(new CustomEvent('manabi-ebook-layout-complete', {
                    detail: {
                        layoutVersion: this.#layoutVersion,
                        pageCount: this.pageCount(),
                    },
                }))
            } catch (_error) {}
        }
    }

    #normalizeSourceAnchor(anchor, fallbackPageIndex = 0) {
        const sourceDoc = this.#sourceDoc
        const anchorDoc = anchor?.startContainer?.getRootNode?.() ?? anchor?.ownerDocument ?? null
        if (sourceDoc && anchorDoc === sourceDoc) {
            return anchor
        }
        return this.sourceRangeForPage(fallbackPageIndex)
            || this.sourceRangeForPage(0)
            || this.#currentSourceAnchor
    }

    #sourceAnchorForUnitIndex(unitIndex) {
        const unit = this.#unitRecords[unitIndex]
        if (!unit) return null
        if (unit.type === 'text' && this.#sourceDoc) {
            const range = this.#sourceDoc.createRange()
            range.setStart(unit.sourceNode, unit.sourceStartOffset)
            range.collapse(true)
            return range
        }
        return unit.sourceNode ?? null
    }

    #sourceLocationForUnitIndex(unitIndex) {
        const unit = this.#unitRecords[unitIndex]
        if (!unit) return null
        return {
            sourceNode: unit.sourceNode,
            sourceOffset: unit.type === 'text' ? unit.sourceStartOffset : 0,
        }
    }

    #sourceAnchorForLocation(location) {
        const sourceNode = location?.sourceNode
        if (!sourceNode) return null
        if (sourceNode.nodeType === Node.TEXT_NODE && this.#sourceDoc) {
            const range = this.#sourceDoc.createRange()
            range.setStart(sourceNode, location.sourceOffset ?? 0)
            range.collapse(true)
            return range
        }
        return sourceNode
    }

    #unitContainsSourceLocation(unit, location) {
        if (!unit || !location?.sourceNode || unit.sourceNode !== location.sourceNode) {
            return false
        }
        if (unit.type !== 'text') {
            return true
        }
        const sourceOffset = Number.isFinite(location.sourceOffset) ? location.sourceOffset : 0
        return sourceOffset >= unit.sourceStartOffset && sourceOffset < unit.sourceEndOffset
    }

    #sentenceIdentifierForNode(node) {
        if (!node) return null
        const sentenceNode = node.nodeType === Node.ELEMENT_NODE
            ? node.closest?.('manabi-sentence')
            : node.parentElement?.closest?.('manabi-sentence')
        return sentenceNode?.dataset?.sentenceIdentifier || null
    }

    #sentenceIdentifierForAnchor(anchor) {
        if (!anchor) return null
        if (isRangeLike(anchor)) {
            return this.#sentenceIdentifierForNode(anchor.startContainer)
        }
        return this.#sentenceIdentifierForNode(anchor)
    }

    #sentenceIdentifierForUnitIndex(unitIndex) {
        const unit = this.#unitRecords[unitIndex]
        return this.#sentenceIdentifierForNode(unit?.sourceNode)
    }

    #unitIndexForSentenceIdentifier(sentenceIdentifier) {
        if (!sentenceIdentifier) return null
        for (let index = 0; index < this.#unitRecords.length; index += 1) {
            if (this.#sentenceIdentifierForUnitIndex(index) === sentenceIdentifier) {
                return index
            }
        }
        return null
    }

    #unitIndexForAnchorNode(node, offset = 0) {
        if (!node) return null
        if (node.nodeType === Node.TEXT_NODE) {
            const indices = this.#unitIndicesBySourceNode.get(node)
            if (indices?.length) {
                for (const index of indices) {
                    const unit = this.#unitRecords[index]
                    if (unit.type === 'text' && offset < unit.sourceEndOffset) {
                        return index
                    }
                }
                return indices[indices.length - 1]
            }
        }
        if (node.nodeType === Node.ELEMENT_NODE) {
            const directIndices = this.#unitIndicesBySourceNode.get(node)
            if (directIndices?.length) return directIndices[0]
            const walker = node.ownerDocument?.createTreeWalker?.(
                node,
                NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT
            )
            let current = walker?.currentNode
            while (current) {
                const currentIndices = this.#unitIndicesBySourceNode.get(current)
                if (currentIndices?.length) return currentIndices[0]
                current = walker.nextNode()
            }
        }
        let ancestor = node.parentNode
        while (ancestor) {
            const indices = this.#unitIndicesBySourceNode.get(ancestor)
            if (indices?.length) return indices[0]
            ancestor = ancestor.parentNode
        }
        return null
    }
}
