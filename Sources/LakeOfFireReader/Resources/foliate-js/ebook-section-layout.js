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
const STAGING_ROOT_ID_SUFFIX = '-ebook-layout-staging'

const logReaderPerf = (event, detail = {}) => {
    try {
        const line = `# READERPERF ${JSON.stringify({ event, ...detail })}`
        globalThis.window?.webkit?.messageHandlers?.print?.postMessage?.(line)
    } catch (_error) {}
}

const perfNow = () => globalThis.performance?.now?.() ?? Date.now()

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

const createStagingRootForLiveRoot = liveRoot => {
    if (!(liveRoot instanceof HTMLElement)) return null
    const doc = liveRoot.ownerDocument
    const stagingRoot = doc.createElement(liveRoot.tagName.toLowerCase())
    const liveRect = liveRoot.getBoundingClientRect?.() || { width: 0, height: 0 }
    const viewportWidth = doc.defaultView?.innerWidth ?? 0
    const viewportHeight = doc.defaultView?.innerHeight ?? 0
    const width = Math.max(1, Math.round(liveRect.width || viewportWidth || 1))
    const height = Math.max(1, Math.round(liveRect.height || viewportHeight || 1))
    copyAttributes(liveRoot, stagingRoot)
    stagingRoot.id = `${liveRoot.id || 'reader-content'}${STAGING_ROOT_ID_SUFFIX}`
    stagingRoot.setAttribute('aria-hidden', 'true')
    stagingRoot.dataset.manabiLayoutStaging = 'true'
    stagingRoot.style.position = 'fixed'
    stagingRoot.style.left = '-200vw'
    stagingRoot.style.top = '0'
    stagingRoot.style.inlineSize = `${width}px`
    stagingRoot.style.blockSize = `${height}px`
    stagingRoot.style.visibility = 'hidden'
    stagingRoot.style.pointerEvents = 'none'
    stagingRoot.style.overflow = 'hidden'
    liveRoot.parentNode?.insertBefore?.(stagingRoot, liveRoot.nextSibling)
    return stagingRoot
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

const applyPageRootLayoutStyles = root => {
    if (!(root instanceof HTMLElement)) return
    root.style.position = 'relative'
    root.style.inlineSize = '100%'
    root.style.blockSize = '100%'
    root.style.boxSizing = 'border-box'
    root.style.overflow = 'hidden'
}

const applyPageLayoutStyles = pageNode => {
    if (!(pageNode instanceof HTMLElement)) return
    pageNode.style.inlineSize = '100%'
    pageNode.style.blockSize = '100%'
    pageNode.style.boxSizing = 'border-box'
    pageNode.style.overflow = 'hidden'
}

const applyChunkLayoutStyles = (chunkNode, chunkBody) => {
    if (chunkNode instanceof HTMLElement) {
        chunkNode.style.inlineSize = '100%'
        chunkNode.style.blockSize = '100%'
        chunkNode.style.boxSizing = 'border-box'
        chunkNode.style.overflow = 'hidden'
    }
    if (chunkBody instanceof HTMLElement) {
        chunkBody.style.inlineSize = '100%'
        chunkBody.style.blockSize = '100%'
        chunkBody.style.boxSizing = 'border-box'
        chunkBody.style.overflow = 'hidden'
    }
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
    applyChunkLayoutStyles(chunkNode, chunkBody)
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
    #stagingRoot = null
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
                layoutDiagnostics: () => this.layoutDiagnostics(),
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
        this.#removeStagingRoot()
        if (this.#doc?.defaultView?.manabiEbookSectionLayoutController === this.#controller) {
            delete this.#doc.defaultView.manabiEbookSectionLayoutController
        }
        this.#doc = null
        this.#root = null
        this.#stagingRoot = null
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
        const liveRoot = this.#root
        if (!(doc instanceof Document) || !(liveRoot instanceof HTMLElement)) return null
        if (doc.body?.dataset?.isEbook !== 'true') return null

        const buildStart = perfNow()
        let result = null
        this.#runWithSuppressedMutations(() => {
            this.#cancelWarmup()
            doc.documentElement.dataset.manabiLayoutComplete = 'false'

            const snapshotStart = perfNow()
            const units = this.#prepareSourceSnapshot({ doc, runtime, root: liveRoot })
            const snapshotDurationMs = Math.round((perfNow() - snapshotStart) * 100) / 100
            if (!units?.length) {
                liveRoot.innerHTML = ''
                liveRoot.classList.add('manabi-page-root')
                applyPageRootLayoutStyles(liveRoot)
                this.#pageRecords = []
                this.#buildState = null
                this.#refreshLiveRoot({ runtime, root: liveRoot, complete: true })
                logReaderPerf('ebook-layout-build-finished', {
                    reason,
                    snapshotDurationMs,
                    buildDurationMs: 0,
                    commitDurationMs: 0,
                    totalDurationMs: Math.round((perfNow() - buildStart) * 100) / 100,
                    pageCount: 0,
                    layoutComplete: true,
                })
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
            const targetSentenceIdentifier = this.#sentenceIdentifierForAnchor(resolvedAnchor)
                || location?.anchorSentenceIdentifier
                || this.#sentenceIdentifierForUnitIndex(targetUnitIndex)
            const targetSourceLocation = this.#sourceLocationForAnchor(resolvedAnchor)
                || this.#sourceLocationForSentenceIdentifier(targetSentenceIdentifier)
                || location?.anchorSourceLocation
                || this.#sourceLocationForUnitIndex(targetUnitIndex, 'start')
            logReaderPerf('ebook-layout-build-target', {
                reason,
                targetUnitIndex,
                anchorSentenceIdentifier: this.#sentenceIdentifierForAnchor(resolvedAnchor),
                targetSentenceIdentifier: this.#sentenceIdentifierForUnitIndex(targetUnitIndex),
                locationAnchorUnitIndex: location?.anchorUnitIndex ?? null,
                locationAnchorSentenceIdentifier: location?.anchorSentenceIdentifier ?? null,
            })

            const buildLayoutStart = perfNow()
            this.#buildState = this.#createBuildState({
                doc,
                runtime,
                liveRoot,
                metrics,
                columnCount,
                units,
                layoutVersion: this.#layoutVersion,
                targetUnitIndex,
                targetSourceLocation,
            })
            this.#continueBuilding()
            const buildDurationMs = Math.round((perfNow() - buildLayoutStart) * 100) / 100

            const fallbackPageIndex = Math.max(0, this.#unitRecords[targetUnitIndex]?.pageIndex ?? 0)
            this.#currentSourceAnchor = this.#sourceAnchorForLocation(targetSourceLocation)
                || this.#sourceAnchorForSentenceIdentifier(targetSentenceIdentifier)
                || this.#sourceAnchorForUnitIndex(targetUnitIndex)
                || this.#normalizeSourceAnchor(resolvedAnchor, fallbackPageIndex)
            logReaderPerf('ebook-layout-current-anchor', {
                reason,
                fallbackPageIndex,
                currentSentenceIdentifier: this.#sentenceIdentifierForAnchor(this.#currentSourceAnchor),
            })
            const commitStart = perfNow()
            this.#commitStagingRootToLiveRoot({
                liveRoot,
                stagingRoot: this.#buildState?.root ?? this.#stagingRoot,
            })
            this.#refreshLiveRoot({
                runtime,
                root: liveRoot,
                complete: this.isLayoutComplete(),
            })
            const commitDurationMs = Math.round((perfNow() - commitStart) * 100) / 100
            if (!this.isLayoutComplete()) {
                this.#scheduleWarmup()
            } else {
                this.#removeStagingRoot()
            }
            logReaderPerf('ebook-layout-build-finished', {
                reason,
                snapshotDurationMs,
                buildDurationMs,
                commitDurationMs,
                totalDurationMs: Math.round((perfNow() - buildStart) * 100) / 100,
                pageCount: this.pageCount(),
                layoutComplete: this.isLayoutComplete(),
            })

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

    layoutDiagnostics() {
        const resolvedCurrentPageIndex = this.pageIndexForAnchor(this.#currentSourceAnchor) ?? 0
        const currentPageRecord = this.#pageRecords[resolvedCurrentPageIndex] ?? null
        const activeBuildPageRecord = this.#buildState?.pageRecord ?? null
        const currentChunkCount = currentPageRecord?.chunkRecords?.length ?? 0
        const activeBuildChunkCount = activeBuildPageRecord?.chunkRecords?.length ?? 0
        const maxPageChunkCount = this.#pageRecords.reduce(
            (max, pageRecord) => Math.max(max, pageRecord?.chunkRecords?.length ?? 0),
            0
        )
        const buildMetrics = this.#buildState?.metrics ?? {
            vertical: this.#doc?.body?.classList?.contains?.('reader-vertical-writing') === true,
            verticalRTL: true,
        }
        return {
            pageCount: this.pageCount(),
            pageRecordCount: this.#pageRecords.length,
            currentPageIndex: resolvedCurrentPageIndex,
            currentPageChunkCount: currentChunkCount,
            maxPageChunkCount,
            activeBuildPageIndex: this.#buildState?.pageIndex ?? null,
            activeBuildChunkCount,
            columnCount: this.#buildState?.columnCount ?? currentChunkCount ?? 1,
            spreadCandidateDetected: maxPageChunkCount > 1,
            vertical: buildMetrics?.vertical ?? null,
            writingMode: buildMetrics?.vertical === true
                ? (buildMetrics?.verticalRTL === true ? 'vertical-rl' : 'vertical-lr')
                : 'horizontal-tb',
            layoutComplete: this.isLayoutComplete(),
        }
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
            startSourceLocation: this.#sourceLocationForUnitIndex(pageRecord.startUnitIndex, 'start'),
            endSourceLocation: this.#sourceLocationForUnitIndex(pageRecord.endUnitIndex, 'end'),
            anchorSourceLocation: this.#sourceLocationForAnchor(this.#currentSourceAnchor)
                || this.#sourceLocationForUnitIndex(anchorUnitIndex, 'start'),
            layoutVersion: this.#layoutVersion,
        }
    }

    pageIndexForLocation(location) {
        const anchorUnitIndex = this.#sourceUnitIndexForLocation(location?.anchorSourceLocation)
            ?? this.#unitIndexForSentenceIdentifier(location?.anchorSentenceIdentifier)
            ?? location?.anchorUnitIndex
        if (Number.isFinite(anchorUnitIndex)) {
            return this.#unitRecords[anchorUnitIndex]?.pageIndex ?? location?.pageIndex ?? null
        }
        return Number.isFinite(location?.pageIndex) ? location.pageIndex : null
    }

    sourceRangeForLocation(location) {
        const resolvedPageIndex = this.pageIndexForLocation(location)
        const resolvedPageRecord = Number.isFinite(resolvedPageIndex)
            ? this.#pageRecords[resolvedPageIndex]
            : null
        if (resolvedPageRecord && resolvedPageRecord.startUnitIndex != null && resolvedPageRecord.endUnitIndex != null && this.#sourceDoc) {
            const currentPageRange = this.#sourceDoc.createRange()
            this.#setRangeBoundary(
                currentPageRange,
                'start',
                this.#sourceLocationForUnitIndex(resolvedPageRecord.startUnitIndex, 'start')
            )
            this.#setRangeBoundary(
                currentPageRange,
                'end',
                this.#sourceLocationForUnitIndex(resolvedPageRecord.endUnitIndex, 'end')
            )
            if (!currentPageRange.collapsed || currentPageRange.toString()?.length) {
                return currentPageRange
            }
        }

        const startSourceLocation = location?.startSourceLocation
        const endSourceLocation = location?.endSourceLocation
        if (startSourceLocation?.sourceNode && endSourceLocation?.sourceNode && this.#sourceDoc) {
            const range = this.#sourceDoc.createRange()
            this.#setRangeBoundary(range, 'start', startSourceLocation)
            this.#setRangeBoundary(range, 'end', endSourceLocation)
            if (!range.collapsed || range.toString()?.length) {
                return range
            }
        }
        const startUnitIndex = location?.startUnitIndex
        const endUnitIndex = location?.endUnitIndex
        if (!Number.isFinite(startUnitIndex) || !Number.isFinite(endUnitIndex)) return null
        const startUnit = this.#unitRecords[startUnitIndex]
        const endUnit = this.#unitRecords[endUnitIndex]
        if (!startUnit || !endUnit || !this.#sourceDoc) return null
        const range = this.#sourceDoc.createRange()
        this.#setRangeBoundary(range, 'start', this.#sourceLocationForUnitIndex(startUnitIndex, 'start'))
        this.#setRangeBoundary(range, 'end', this.#sourceLocationForUnitIndex(endUnitIndex, 'end'))
        if (!range.collapsed || range.toString()?.length) {
            return range
        }
        const pageIndex = resolvedPageIndex
        const pageRecord = resolvedPageRecord
        if (!pageRecord || pageRecord.startUnitIndex == null || pageRecord.endUnitIndex == null) {
            return range
        }
        const pageRange = this.#sourceDoc.createRange()
        this.#setRangeBoundary(pageRange, 'start', this.#sourceLocationForUnitIndex(pageRecord.startUnitIndex, 'start'))
        this.#setRangeBoundary(pageRange, 'end', this.#sourceLocationForUnitIndex(pageRecord.endUnitIndex, 'end'))
        return pageRange
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
        } else if (
            this.#sourceDoc instanceof Document
            && this.#sourceRoot instanceof HTMLElement
            && this.#unitRecords.length > 0
        ) {
            logReaderPerf('ebook-layout-source-snapshot-reused', {
                unitCount: this.#unitRecords.length,
                layoutVersion: this.#layoutVersion,
            })
            return this.#unitRecords
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
        logReaderPerf('ebook-layout-source-snapshot-built', {
            unitCount: this.#unitRecords.length,
            layoutVersion: this.#layoutVersion,
        })
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
        const locationAnchorUnitIndex = this.#sourceUnitIndexForLocation(location?.anchorSourceLocation)
            ?? this.#unitIndexForSentenceIdentifier(location?.anchorSentenceIdentifier)
            ?? location?.anchorUnitIndex
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
        liveRoot,
        metrics,
        columnCount,
        units,
        layoutVersion,
        targetUnitIndex,
        targetSourceLocation,
    }) {
        this.#removeStagingRoot()
        const root = createStagingRootForLiveRoot(liveRoot)
        if (!(root instanceof HTMLElement)) {
            throw new Error('Unable to create ebook layout staging root.')
        }
        this.#stagingRoot = root
        root.innerHTML = ''
        root.classList.add('manabi-page-root')
        applyPageRootLayoutStyles(root)
        root.dataset.manabiLayoutVersion = String(layoutVersion)
        this.#pageRecords = []

        const pageNode = doc.createElement('div')
        pageNode.className = 'manabi-page'
        pageNode.dataset.manabiPageIndex = '0'
        applyPageLayoutStyles(pageNode)
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
            liveRoot,
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
            applyPageLayoutStyles(state.pageNode)
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

    #removeStagingRoot() {
        this.#stagingRoot?.remove?.()
        this.#stagingRoot = null
    }

    #commitStagingRootToLiveRoot({ liveRoot, stagingRoot }) {
        if (!(liveRoot instanceof HTMLElement) || !(stagingRoot instanceof HTMLElement)) return
        const commitStart = perfNow()
        liveRoot.className = stagingRoot.className
        liveRoot.dataset.manabiLayoutVersion = stagingRoot.dataset.manabiLayoutVersion || ''
        liveRoot.innerHTML = stagingRoot.innerHTML
        logReaderPerf('ebook-layout-commit-live-root', {
            childCount: liveRoot.childElementCount,
            htmlLength: liveRoot.innerHTML.length,
            commitInnerHTMLDurationMs: Math.round((perfNow() - commitStart) * 100) / 100,
        })
    }

    #syncChunkSourceMetadata() {
        for (const pageRecord of this.#pageRecords) {
            for (const chunkRecord of pageRecord.chunkRecords || []) {
                const chunkNode = chunkRecord?.chunkNode
                if (!(chunkNode instanceof HTMLElement)) continue
                const startUnitIndex = chunkRecord.startUnitIndex
                const endUnitIndex = chunkRecord.endUnitIndex
                if (!Number.isFinite(startUnitIndex) || !Number.isFinite(endUnitIndex)) continue
                chunkNode.dataset.manabiSourceStartUnitIndex = String(startUnitIndex)
                chunkNode.dataset.manabiSourceEndUnitIndex = String(endUnitIndex)
                const startSentenceIdentifier = this.#sentenceIdentifierForUnitIndex(startUnitIndex)
                const endSentenceIdentifier = this.#sentenceIdentifierForUnitIndex(endUnitIndex)
                if (startSentenceIdentifier) {
                    chunkNode.dataset.manabiSourceStartSentenceIdentifier = startSentenceIdentifier
                } else {
                    delete chunkNode.dataset.manabiSourceStartSentenceIdentifier
                }
                if (endSentenceIdentifier) {
                    chunkNode.dataset.manabiSourceEndSentenceIdentifier = endSentenceIdentifier
                } else {
                    delete chunkNode.dataset.manabiSourceEndSentenceIdentifier
                }
            }
        }
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
            const warmupStart = perfNow()
            const pageCountBefore = this.pageCount()
            const nextVisiblePageIndex = Math.max(0, this.pageCount() + WARMUP_PAGE_BATCH - 1)
            this.#buildState.stopAfterPageIndex = Math.max(
                nextVisiblePageIndex,
                this.#buildState.stopAfterPageIndex ?? -1
            )
            this.#continueBuilding()
            this.#commitStagingRootToLiveRoot({
                liveRoot: root,
                stagingRoot: this.#buildState?.root ?? this.#stagingRoot,
            })
            this.#refreshLiveRoot({
                runtime,
                root,
                complete: this.isLayoutComplete(),
            })
            logReaderPerf('ebook-layout-warmup-batch', {
                layoutVersion: this.#layoutVersion,
                pageCountBefore,
                pageCountAfter: this.pageCount(),
                builtPageCount: Math.max(0, this.pageCount() - pageCountBefore),
                durationMs: Math.round((perfNow() - warmupStart) * 100) / 100,
                layoutComplete: this.isLayoutComplete(),
            })
            if (!this.isLayoutComplete()) {
                this.#scheduleWarmup()
            } else {
                this.#removeStagingRoot()
                logReaderPerf('ebook-layout-warmup-complete', {
                    layoutVersion: this.#layoutVersion,
                    pageCount: this.pageCount(),
                })
            }
        })
    }

    #refreshLiveRoot({ runtime, root, complete }) {
        this.#syncChunkSourceMetadata()
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
        return this.#sourceAnchorForLocation(this.#sourceLocationForUnitIndex(unitIndex, 'start'))
    }

    #sourceAnchorForSentenceIdentifier(sentenceIdentifier) {
        return this.#sourceAnchorForLocation(this.#sourceLocationForSentenceIdentifier(sentenceIdentifier))
    }

    #sourceLocationForAnchor(anchor) {
        if (!anchor) return null
        if (isRangeLike(anchor)) {
            return this.#sourceLocationForBoundaryNode(anchor.startContainer, anchor.startOffset)
                || this.#sourceLocationForNode(anchor.startContainer)
        }
        return this.#sourceLocationForNode(anchor)
    }

    #sourceLocationForUnitIndex(unitIndex, edge = 'start') {
        const unit = this.#unitRecords[unitIndex]
        if (!unit) return null
        return {
            sourceNode: unit.sourceNode,
            sourceOffset: unit.type === 'text'
                ? (edge === 'end' ? unit.sourceEndOffset : unit.sourceStartOffset)
                : 0,
            edge,
        }
    }

    #sourceLocationForSentenceIdentifier(sentenceIdentifier) {
        const unitIndex = this.#unitIndexForSentenceIdentifier(sentenceIdentifier)
        return Number.isFinite(unitIndex)
            ? this.#sourceLocationForUnitIndex(unitIndex, 'start')
            : null
    }

    #sourceAnchorForLocation(location) {
        const sourceNode = location?.sourceNode
        if (!sourceNode || !this.#sourceDoc) return null
        const range = this.#sourceDoc.createRange()
        this.#setRangeBoundary(range, 'start', location)
        range.collapse(true)
        return range
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

    #sourceUnitIndexForLocation(location) {
        const anchor = this.#sourceAnchorForLocation(location)
        return this.#sourceUnitIndexForAnchor(anchor)
    }

    #setRangeBoundary(range, edge, location) {
        const sourceNode = location?.sourceNode
        if (!range || !sourceNode) return
        const isStart = edge === 'start'
        if (sourceNode.nodeType === Node.TEXT_NODE) {
            const offset = Math.max(0, Number.isFinite(location?.sourceOffset) ? location.sourceOffset : 0)
            if (isStart) {
                range.setStart(sourceNode, offset)
            } else {
                range.setEnd(sourceNode, offset)
            }
            return
        }
        if (sourceNode.nodeType === Node.ELEMENT_NODE) {
            const boundaryOffset = isStart ? 0 : sourceNode.childNodes.length
            if (isStart) {
                range.setStart(sourceNode, boundaryOffset)
            } else {
                range.setEnd(sourceNode, boundaryOffset)
            }
            return
        }
        if (isStart) {
            range.setStartBefore(sourceNode)
        } else {
            range.setEndAfter(sourceNode)
        }
    }

    #sourceLocationForBoundaryNode(node, offset = 0) {
        if (!node) return null
        if (node.nodeType === Node.TEXT_NODE) {
            return {
                sourceNode: node,
                sourceOffset: Math.max(0, Math.min(node.nodeValue?.length ?? 0, offset)),
                edge: 'start',
            }
        }
        if (node.nodeType !== Node.ELEMENT_NODE) {
            return this.#sourceLocationForNode(node)
        }
        const childNodes = Array.from(node.childNodes || [])
        const preferredChild = childNodes[offset] || childNodes[childNodes.length - 1] || null
        return this.#sourceLocationForNode(preferredChild)
            || this.#sourceLocationForNode(node)
    }

    #sourceLocationForNode(node) {
        if (!node) return null
        if (node.nodeType === Node.TEXT_NODE) {
            return {
                sourceNode: node,
                sourceOffset: 0,
                edge: 'start',
            }
        }
        if (node.nodeType !== Node.ELEMENT_NODE) return null
        const directUnitIndices = this.#unitIndicesBySourceNode.get(node)
        if (directUnitIndices?.length) {
            return this.#sourceLocationForUnitIndex(directUnitIndices[0], 'start')
        }
        const walker = node.ownerDocument?.createTreeWalker?.(
            node,
            NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT
        )
        let current = walker?.currentNode
        while (current) {
            if (current !== node) {
                const currentUnitIndices = this.#unitIndicesBySourceNode.get(current)
                if (currentUnitIndices?.length) {
                    return this.#sourceLocationForUnitIndex(currentUnitIndices[0], 'start')
                }
                if (current.nodeType === Node.TEXT_NODE && shouldKeepChunkTextNode(current)) {
                    return {
                        sourceNode: current,
                        sourceOffset: 0,
                        edge: 'start',
                    }
                }
            }
            current = walker?.nextNode?.() || null
        }
        return {
            sourceNode: node,
            sourceOffset: 0,
            edge: 'start',
        }
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
