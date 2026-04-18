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
const PRESERVED_SOURCE_SNAPSHOT_KEY = '__manabiEbookPreservedSourceSnapshot'
const MIN_CHUNK_UNITS_BEFORE_OVERFLOW_BOUNDARY = 12
const MIN_CHUNK_TEXT_LENGTH_BEFORE_OVERFLOW_BOUNDARY = 20

const deriveVisibleUnitDiagnostics = ({
    columnCount,
    spreadCandidateDetected,
    vertical,
    currentPageIndex = null,
    pageCount = null,
}) => {
    const resolvedColumnCount = Math.max(1, Number.parseInt(String(columnCount || 1), 10) || 1)
    const multiUnitActive = spreadCandidateDetected === true && resolvedColumnCount > 1
    const visibleUnitKind = multiUnitActive
        ? (vertical === true ? 'paginatedRowSet' : 'pageSpread')
        : 'singlePage'
    const visibleUnitAxis = vertical === true ? 'vertical' : 'horizontal'
    const visiblePageCount = multiUnitActive ? resolvedColumnCount : 1
    const currentUnitIndex = Number.isFinite(currentPageIndex)
        ? Math.floor(currentPageIndex / visiblePageCount)
        : null
    const leadingPageIndex = Number.isFinite(currentPageIndex)
        ? currentPageIndex - (currentPageIndex % visiblePageCount)
        : null
    const trailingPageIndex = leadingPageIndex != null
        ? leadingPageIndex + Math.max(0, visiblePageCount - 1)
        : null
    const resolvedPageCount = Number.isFinite(pageCount)
        ? Math.max(0, Number.parseInt(String(pageCount), 10) || 0)
        : null
    const hasLeadingSingleton = multiUnitActive
        && leadingPageIndex === 0
        && currentPageIndex === 0
    const hasTrailingSingleton = multiUnitActive
        && resolvedPageCount != null
        && leadingPageIndex != null
        && leadingPageIndex > 0
        && (resolvedPageCount - leadingPageIndex) === 1
    return {
        visibleUnitKind,
        visibleUnitAxis,
        visiblePageCount,
        currentUnitIndex,
        leadingPageIndex,
        trailingPageIndex,
        hasLeadingSingleton,
        hasTrailingSingleton,
        multiUnitActive,
        spreadPagesAllowedForViewport: multiUnitActive,
    }
}

const deriveSpreadSequenceDiagnostics = ({
    currentPageIndex = null,
    pageCount = null,
    visiblePageCount = 1,
    hasLeadingSingleton = false,
    hasTrailingSingleton = false,
}) => {
    if (!Number.isFinite(currentPageIndex) || !Number.isFinite(pageCount) || pageCount <= 0) {
        return null
    }

    const resolvedVisiblePageCount = Math.max(1, Number.parseInt(String(visiblePageCount || 1), 10) || 1)
    const spreads = []
    let pageIndex = 0

    if (resolvedVisiblePageCount > 1 && hasLeadingSingleton === true && pageIndex < pageCount) {
        spreads.push({
            index: spreads.length,
            slots: [
                { kind: 'blank', pageIndex: null },
                { kind: 'page', pageIndex },
            ],
        })
        pageIndex += 1
    }

    while (pageIndex < pageCount) {
        const remaining = pageCount - pageIndex
        if (resolvedVisiblePageCount > 1 && hasTrailingSingleton === true && remaining === 1) {
            spreads.push({
                index: spreads.length,
                slots: [
                    { kind: 'page', pageIndex },
                    { kind: 'blank', pageIndex: null },
                ],
            })
            pageIndex += 1
            continue
        }

        const slotCount = Math.min(resolvedVisiblePageCount, remaining)
        const slots = []
        for (let offset = 0; offset < slotCount; offset += 1) {
            slots.push({
                kind: 'page',
                pageIndex: pageIndex + offset,
            })
        }
        spreads.push({
            index: spreads.length,
            slots,
        })
        pageIndex += slotCount
    }

    const currentIndex = spreads.findIndex(spread =>
        Array.isArray(spread?.slots) && spread.slots.some(slot => slot?.pageIndex === currentPageIndex)
    )

    return {
        currentIndex: currentIndex >= 0 ? currentIndex : null,
        spreads,
    }
}

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

const snapshotAttributes = element => {
    if (!(element instanceof Element)) return []
    return Array.from(element.attributes).map(({ name, value }) => ({ name, value }))
}

const applyStoredAttributes = (element, attributes) => {
    if (!(element instanceof Element) || !Array.isArray(attributes)) return
    for (const entry of attributes) {
        if (!entry?.name) continue
        try {
            element.setAttribute(entry.name, entry.value ?? '')
        } catch (_error) {}
    }
}

const resolveSectionRoot = doc => {
    const readerContent = doc?.getElementById?.('reader-content')
    if (!(readerContent instanceof HTMLElement)) return null
    const pageNode = readerContent.querySelector(':scope > .page') || readerContent
    return pageNode.querySelector('article') || pageNode
}

const rootLooksPaginated = root => {
    if (!(root instanceof HTMLElement)) return false
    return root.classList.contains('manabi-page-root')
        || root.querySelector?.('.manabi-page-column-chunk') != null
        || root.querySelector?.('.manabi-page') != null
}

const capturePreservedSourceSnapshot = ({ doc, root }) => {
    if (!(doc instanceof Document) || !(root instanceof HTMLElement)) return null
    return {
        bodyHTML: doc.body?.innerHTML ?? '',
        bodyClassName: doc.body?.className ?? '',
        bodyAttributes: snapshotAttributes(doc.body),
        documentElementAttributes: snapshotAttributes(doc.documentElement),
        rootInnerHTML: root.innerHTML ?? '',
        contentURL: doc.defaultView?.manabiCurrentContentURL ?? doc.URL ?? null,
        capturedAt: Date.now(),
    }
}

const preservedSourceSnapshotForRuntime = runtime => {
    const snapshot = runtime?.[PRESERVED_SOURCE_SNAPSHOT_KEY]
    return snapshot && typeof snapshot === 'object' ? snapshot : null
}

const storePreservedSourceSnapshot = (runtime, snapshot) => {
    if (!runtime || !snapshot) return
    runtime[PRESERVED_SOURCE_SNAPSHOT_KEY] = snapshot
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
        const tagName = clone.tagName?.toLowerCase?.() || ''
        if (clone instanceof HTMLElement && (tagName === 'section' || tagName === 'article' || tagName === 'div')) {
            clone.style.display = 'block'
            clone.style.inlineSize = '100%'
            clone.style.maxInlineSize = '100%'
            clone.style.minInlineSize = '0'
            clone.style.margin = '0'
            clone.style.boxSizing = 'border-box'
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

const normalizedChunkBodyTextLength = chunkBody => {
    if (!(chunkBody instanceof HTMLElement)) return 0
    return (chunkBody.textContent || '').replace(/\s+/g, '').length
}

const shouldDelayChunkOverflowBoundary = (chunkBody, appendState, unit) => {
    const unitCount = appendState?.unitCount ?? 0
    if (unitCount >= MIN_CHUNK_UNITS_BEFORE_OVERFLOW_BOUNDARY) return false
    if (normalizedChunkBodyTextLength(chunkBody) >= MIN_CHUNK_TEXT_LENGTH_BEFORE_OVERFLOW_BOUNDARY) return false
    return unit?.kind === 'segment' || unit?.type === 'text'
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
    root.style.left = '0px'
    root.style.top = '0px'
    root.style.display = 'block'
    root.style.visibility = 'visible'
    root.style.pointerEvents = 'auto'
    root.style.transform = 'none'
    root.style.transition = 'none'
    // Keep the physical page strip LTR so host page indices map to scroll offsets
    // consistently. Individual page content still retains its own document
    // direction and writing mode.
    root.style.direction = 'ltr'
    root.style.inlineSize = '100%'
    root.style.minInlineSize = '100%'
    root.style.maxInlineSize = 'none'
    root.style.blockSize = '100%'
    root.style.boxSizing = 'border-box'
    root.style.overflow = 'visible'
}

const updatePageRootLayoutExtent = (root, { inlineSize = null, pageCount = 1 } = {}) => {
    if (!(root instanceof HTMLElement)) return
    if (Number.isFinite(inlineSize) && inlineSize > 0) {
        const totalInlineSize = Math.max(1, pageCount) * inlineSize
        const totalInlineSizeCSS = `${totalInlineSize}px`
        root.style.inlineSize = totalInlineSizeCSS
        root.style.minInlineSize = totalInlineSizeCSS
    } else {
        root.style.inlineSize = '100%'
        root.style.minInlineSize = '100%'
    }
}

const resolvePageViewportSize = root => {
    if (!(root instanceof HTMLElement)) {
        return { inlineSize: null, blockSize: null }
    }
    const rect = root.getBoundingClientRect?.() ?? null
    const inlineSize = Math.max(
        1,
        Math.round(rect?.width || root.clientWidth || root.offsetWidth || 0)
    )
    const blockSize = Math.max(
        1,
        Math.round(rect?.height || root.clientHeight || root.offsetHeight || 0)
    )
    return {
        inlineSize: Number.isFinite(inlineSize) ? inlineSize : null,
        blockSize: Number.isFinite(blockSize) ? blockSize : null,
    }
}

const applyPageLayoutStyles = (pageNode, { inlineSize = null, blockSize = null, pageIndex = 0 } = {}) => {
    if (!(pageNode instanceof HTMLElement)) return
    pageNode.style.position = 'absolute'
    pageNode.style.left = Number.isFinite(inlineSize) && inlineSize > 0
        ? `${Math.max(0, pageIndex) * inlineSize}px`
        : '0px'
    pageNode.style.top = '0px'
    pageNode.style.display = 'flex'
    pageNode.style.flexDirection = 'row'
    pageNode.style.flex = '0 0 auto'
    if (Number.isFinite(inlineSize) && inlineSize > 0) {
        const inlineSizeCSS = `${inlineSize}px`
        pageNode.style.inlineSize = inlineSizeCSS
        pageNode.style.minInlineSize = inlineSizeCSS
        pageNode.style.maxInlineSize = inlineSizeCSS
    } else {
        pageNode.style.inlineSize = '100%'
        pageNode.style.minInlineSize = '100%'
        pageNode.style.maxInlineSize = '100%'
    }
    if (Number.isFinite(blockSize) && blockSize > 0) {
        const blockSizeCSS = `${blockSize}px`
        pageNode.style.blockSize = blockSizeCSS
        pageNode.style.minBlockSize = blockSizeCSS
    } else {
        pageNode.style.blockSize = '100%'
        pageNode.style.minBlockSize = '100%'
    }
    pageNode.style.boxSizing = 'border-box'
    pageNode.style.gap = '0px'
    pageNode.style.padding = '0 18px 24px 18px'
    pageNode.style.overflow = 'hidden'
}

const applyChunkLayoutStyles = (chunkNode, chunkBody) => {
    if (chunkNode instanceof HTMLElement) {
        chunkNode.style.display = 'flex'
        chunkNode.style.flexDirection = 'column'
        chunkNode.style.flex = '1 1 0'
        chunkNode.style.minInlineSize = '0'
        chunkNode.style.minBlockSize = '0'
        chunkNode.style.inlineSize = '100%'
        chunkNode.style.blockSize = '100%'
        chunkNode.style.boxSizing = 'border-box'
        chunkNode.style.overflow = 'hidden'
    }
    if (chunkBody instanceof HTMLElement) {
        chunkBody.style.display = 'block'
        chunkBody.style.flex = '1 1 auto'
        chunkBody.style.minInlineSize = '0'
        chunkBody.style.minBlockSize = '0'
        chunkBody.style.inlineSize = '100%'
        chunkBody.style.blockSize = '100%'
        chunkBody.style.boxSizing = 'border-box'
        chunkBody.style.overflow = 'hidden'
    }
}

const createChunkSection = ({ doc, pageNode, pageIndex, columnIndex, layoutVersion, runtime }) => {
    const chunkNode = doc.createElement('section')
    chunkNode.className = 'manabi-semantic-section manabi-page-column-chunk'
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
    return { chunkNode, chunkBody }
}

export class EbookSectionLayout {
    _doc = null
    _root = null
    _stagingRoot = null
    _normalizedRootHTML = null
    _sourceDoc = null
    _sourceRoot = null
    _layoutVersion = 0
    _pageRecords = []
    _unitRecords = []
    _unitIndicesBySourceNode = new Map()
    _controller = null
    _currentSourceAnchor = null
    _buildState = null
    _warmupTimer = null
    _warmupToken = 0
    _sourceContentURL = null

    attach(doc) {
        if (this._doc === doc) return
        this.destroy()
        this._doc = doc
        this._root = resolveSectionRoot(doc)
        if (doc?.defaultView) {
            this._controller = {
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
                        return this.buildFromAnchor(anchor ?? this._currentSourceAnchor ?? 0, {
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
            doc.defaultView.manabiEbookSectionLayoutController = this._controller
        }
    }

    destroy() {
        this._cancelWarmup()
        this._removeStagingRoot()
        if (this._doc?.defaultView?.manabiEbookSectionLayoutController === this._controller) {
            delete this._doc.defaultView.manabiEbookSectionLayoutController
        }
        this._doc = null
        this._root = null
        this._stagingRoot = null
        this._normalizedRootHTML = null
        this._sourceDoc = null
        this._sourceRoot = null
        this._layoutVersion = 0
        this._pageRecords = []
        this._unitRecords = []
        this._unitIndicesBySourceNode = new Map()
        this._controller = null
        this._currentSourceAnchor = null
        this._buildState = null
        this._sourceContentURL = null
    }

    getSourceDocument() {
        return this._sourceDoc
    }

    ensureSourceDocument() {
        const doc = this._doc
        const runtime = doc?.defaultView
        const root = this._root
        if (!(doc instanceof Document) || !(root instanceof HTMLElement)) return null
        if (doc.body?.dataset?.isEbook !== 'true') return null
        return this._runWithSuppressedMutations(() => {
            this._prepareSourceSnapshot({ doc, runtime, root })
            return this._sourceDoc
        })
    }

    setCurrentSourceAnchor(anchor) {
        if (!anchor) return null
        this._currentSourceAnchor = anchor
        return anchor
    }

    getCurrentSourceAnchor() {
        return this._currentSourceAnchor
    }

    invalidate({ reason = 'unknown' } = {}) {
        return this.rebuildFromCurrentLocation({ reason })
    }

    build({ reason = 'unknown', anchor = this._currentSourceAnchor ?? 0, anchorResolver = null, location = null } = {}) {
        return this.buildFromAnchor(anchor, { reason, anchorResolver, location })
    }

    buildFromAnchor(anchor, { reason = 'unknown', anchorResolver = null, location = null } = {}) {
        const doc = this._doc
        const runtime = doc?.defaultView
        const liveRoot = this._root
        if (!(doc instanceof Document) || !(liveRoot instanceof HTMLElement)) return null
        if (doc.body?.dataset?.isEbook !== 'true') return null

        const buildStart = perfNow()
        let result = null
        this._runWithSuppressedMutations(() => {
            this._cancelWarmup()
            doc.documentElement.dataset.manabiLayoutComplete = 'false'

            const snapshotStart = perfNow()
            const units = this._prepareSourceSnapshot({ doc, runtime, root: liveRoot })
            const snapshotDurationMs = Math.round((perfNow() - snapshotStart) * 100) / 100
            if (!units?.length) {
                liveRoot.innerHTML = ''
                liveRoot.classList.add('manabi-page-root')
                applyPageRootLayoutStyles(liveRoot)
                this._pageRecords = []
                this._buildState = null
                this._refreshLiveRoot({ runtime, root: liveRoot, complete: true })
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
            this._layoutVersion += 1
            doc.documentElement.dataset.manabiLayoutVersion = String(this._layoutVersion)
            const resolvedAnchor = typeof anchorResolver === 'function'
                ? (anchorResolver(this._sourceDoc || doc) ?? anchorResolver(doc))
                : anchor
            const targetUnitIndex = this._resolveTargetUnitIndexFromLocationOrAnchor(location, resolvedAnchor)
            const targetSentenceIdentifier = this._sentenceIdentifierForAnchor(resolvedAnchor)
                || location?.anchorSentenceIdentifier
                || this._sentenceIdentifierForUnitIndex(targetUnitIndex)
            const targetSourceLocation = this._sourceLocationForAnchor(resolvedAnchor)
                || this._sourceLocationForSentenceIdentifier(targetSentenceIdentifier)
                || location?.anchorSourceLocation
                || this._sourceLocationForUnitIndex(targetUnitIndex, 'start')
            logReaderPerf('ebook-layout-build-target', {
                reason,
                targetUnitIndex,
                anchorSentenceIdentifier: this._sentenceIdentifierForAnchor(resolvedAnchor),
                targetSentenceIdentifier: this._sentenceIdentifierForUnitIndex(targetUnitIndex),
                locationAnchorUnitIndex: location?.anchorUnitIndex ?? null,
                locationAnchorSentenceIdentifier: location?.anchorSentenceIdentifier ?? null,
            })

            const buildLayoutStart = perfNow()
            this._buildState = this._createBuildState({
                doc,
                runtime,
                liveRoot,
                metrics,
                columnCount,
                units,
                layoutVersion: this._layoutVersion,
                targetUnitIndex,
                targetSourceLocation,
            })
            this._continueBuilding()
            const buildDurationMs = Math.round((perfNow() - buildLayoutStart) * 100) / 100

            const fallbackPageIndex = Math.max(0, this._unitRecords[targetUnitIndex]?.pageIndex ?? 0)
            this._currentSourceAnchor = this._sourceAnchorForLocation(targetSourceLocation)
                || this._sourceAnchorForSentenceIdentifier(targetSentenceIdentifier)
                || this._sourceAnchorForUnitIndex(targetUnitIndex)
                || this._normalizeSourceAnchor(resolvedAnchor, fallbackPageIndex)
            logReaderPerf('ebook-layout-current-anchor', {
                reason,
                fallbackPageIndex,
                currentSentenceIdentifier: this._sentenceIdentifierForAnchor(this._currentSourceAnchor),
            })
            const commitStart = perfNow()
            this._commitStagingRootToLiveRoot({
                liveRoot,
                stagingRoot: this._buildState?.root ?? this._stagingRoot,
            })
            this._refreshLiveRoot({
                runtime,
                root: liveRoot,
                complete: this.isLayoutComplete(),
            })
            const commitDurationMs = Math.round((perfNow() - commitStart) * 100) / 100
            if (!this.isLayoutComplete()) {
                this._scheduleWarmup()
            } else {
                this._removeStagingRoot()
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
        const currentPageIndex = this.pageIndexForAnchor(this._currentSourceAnchor)
        const location = currentPageIndex != null
            ? this.captureLocationForPage(currentPageIndex)
            : null
        return this.build({
            reason,
            anchor: this._currentSourceAnchor ?? 0,
            location,
        })
    }

    pageCount() {
        return this._effectivePageCount()
    }

    isLayoutComplete() {
        return this._buildState == null
    }

    hasPendingWarmup() {
        return !this.isLayoutComplete()
    }

    layoutDiagnostics() {
        const resolvedCurrentPageIndex = this.pageIndexForAnchor(this._currentSourceAnchor) ?? 0
        const currentPageRecord = this._pageRecords[resolvedCurrentPageIndex] ?? null
        const activeBuildPageRecord = this._buildState?.pageRecord ?? null
        const liveRoot = this._root ?? null
        const liveCurrentPageNode = liveRoot?.querySelector?.(`:scope > .manabi-page[data-manabi-page-index="${resolvedCurrentPageIndex}"]`) ?? null
            ?? liveRoot?.querySelector?.(`.manabi-page[data-manabi-page-index="${resolvedCurrentPageIndex}"]`) ?? null
            ?? liveRoot?.querySelector?.('.manabi-page') ?? null
        const liveCurrentChunkNode = liveCurrentPageNode?.querySelector?.(`:scope > .manabi-page-column-chunk[data-manabi-column-index="0"]`) ?? null
            ?? liveCurrentPageNode?.querySelector?.(':scope > .manabi-page-column-chunk')
            ?? liveCurrentPageNode?.querySelector?.('.manabi-page-column-chunk')
            ?? null
        const currentChunkBody = liveCurrentChunkNode?.querySelector?.('.manabi-page-column-body') ?? null
        const liveRootRect = liveRoot?.getBoundingClientRect?.() ?? null
        const liveCurrentPageRect = liveCurrentPageNode?.getBoundingClientRect?.() ?? null
        const liveCurrentChunkRect = liveCurrentChunkNode?.getBoundingClientRect?.() ?? null
        const liveCurrentChunkStyle = liveCurrentChunkNode instanceof Element
            ? liveCurrentChunkNode.ownerDocument?.defaultView?.getComputedStyle?.(liveCurrentChunkNode)
            : null
        const currentChunkBodyStyle = currentChunkBody instanceof Element
            ? currentChunkBody.ownerDocument?.defaultView?.getComputedStyle?.(currentChunkBody)
            : null
        const currentChunkCount = currentPageRecord?.chunkRecords?.length ?? 0
        const activeBuildChunkCount = activeBuildPageRecord?.chunkRecords?.length ?? 0
        const maxPageChunkCount = this._pageRecords.reduce(
            (max, pageRecord) => Math.max(max, pageRecord?.chunkRecords?.length ?? 0),
            0
        )
        const buildMetrics = this._buildState?.metrics ?? {
            vertical: this._doc?.body?.classList?.contains?.('reader-vertical-writing') === true,
            verticalRTL: true,
        }
        const spreadCandidateDetected = maxPageChunkCount > 1
        const visibleUnitDiagnostics = deriveVisibleUnitDiagnostics({
            columnCount: this._buildState?.columnCount ?? currentChunkCount ?? 1,
            spreadCandidateDetected,
            vertical: buildMetrics?.vertical === true,
            currentPageIndex: resolvedCurrentPageIndex,
            pageCount: this.pageCount(),
        })
        const spreadSequence = deriveSpreadSequenceDiagnostics({
            currentPageIndex: resolvedCurrentPageIndex,
            pageCount: this.pageCount(),
            visiblePageCount: visibleUnitDiagnostics.visiblePageCount,
            hasLeadingSingleton: visibleUnitDiagnostics.hasLeadingSingleton,
            hasTrailingSingleton: visibleUnitDiagnostics.hasTrailingSingleton,
        })
        return {
            pageCount: this.pageCount(),
            pageRecordCount: this._pageRecords.length,
            liveRootExists: !!liveRoot,
            liveRootClassName: liveRoot?.className ?? null,
            liveRootChildCount: liveRoot?.childElementCount ?? null,
            liveRootRectWidth: liveRootRect ? Math.round(liveRootRect.width) : null,
            liveRootRectHeight: liveRootRect ? Math.round(liveRootRect.height) : null,
            liveCurrentPageExists: !!liveCurrentPageNode,
            liveCurrentPageClassName: liveCurrentPageNode?.className ?? null,
            liveCurrentPageRectWidth: liveCurrentPageRect ? Math.round(liveCurrentPageRect.width) : null,
            liveCurrentPageRectHeight: liveCurrentPageRect ? Math.round(liveCurrentPageRect.height) : null,
            liveCurrentPageContainsChunkBody: liveCurrentPageNode instanceof Element
                ? !!liveCurrentPageNode.querySelector('.manabi-page-column-body')
                : null,
            liveCurrentChunkExists: !!liveCurrentChunkNode,
            liveCurrentChunkTagName: liveCurrentChunkNode?.tagName?.toLowerCase?.() ?? null,
            liveCurrentChunkClassName: liveCurrentChunkNode?.className ?? null,
            liveCurrentChunkDisplay: liveCurrentChunkStyle?.display ?? null,
            liveCurrentChunkPosition: liveCurrentChunkStyle?.position ?? null,
            liveCurrentChunkFlex: liveCurrentChunkStyle?.flex ?? null,
            liveCurrentChunkRectWidth: liveCurrentChunkRect ? Math.round(liveCurrentChunkRect.width) : null,
            liveCurrentChunkRectHeight: liveCurrentChunkRect ? Math.round(liveCurrentChunkRect.height) : null,
            liveCurrentChunkInnerHTMLLength: liveCurrentChunkNode?.innerHTML?.length ?? null,
            liveCurrentChunkContainsChunkBody: liveCurrentChunkNode instanceof Element
                ? !!liveCurrentChunkNode.querySelector('.manabi-page-column-body')
                : null,
            liveCurrentChunkChildCount: liveCurrentChunkNode?.childElementCount ?? null,
            liveCurrentChunkTextLength: liveCurrentChunkNode?.textContent?.length ?? null,
            currentChunkBodyChildCount: currentChunkBody?.childElementCount ?? null,
            currentChunkBodyTextLength: currentChunkBody?.textContent?.length ?? null,
            currentChunkBodyDisplay: currentChunkBodyStyle?.display ?? null,
            currentChunkBodyPosition: currentChunkBodyStyle?.position ?? null,
            currentChunkBodyFlex: currentChunkBodyStyle?.flex ?? null,
            currentPageIndex: resolvedCurrentPageIndex,
            currentPageChunkCount: currentChunkCount,
            maxPageChunkCount,
            activeBuildPageIndex: this._buildState?.pageIndex ?? null,
            activeBuildChunkCount,
            columnCount: this._buildState?.columnCount ?? currentChunkCount ?? 1,
            unitCount: this._unitRecords.length,
            currentChunkClientWidth: currentChunkBody?.clientWidth ?? null,
            currentChunkClientHeight: currentChunkBody?.clientHeight ?? null,
            currentChunkScrollWidth: currentChunkBody?.scrollWidth ?? null,
            currentChunkScrollHeight: currentChunkBody?.scrollHeight ?? null,
            currentChunkOverflow: currentChunkBody instanceof HTMLElement
                ? chunkBodyHasOverflow(currentChunkBody, buildMetrics?.vertical === true)
                : null,
            spreadCandidateDetected,
            vertical: buildMetrics?.vertical ?? null,
            writingMode: buildMetrics?.vertical === true
                ? (buildMetrics?.verticalRTL === true ? 'vertical-rl' : 'vertical-lr')
                : 'horizontal-tb',
            spreadSequence,
            ...visibleUnitDiagnostics,
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
        if (pageIndex < this.pageCount() || this._buildState == null) {
            return {
                pageCount: this.pageCount(),
                reason,
                layoutComplete: this.isLayoutComplete(),
            }
        }

        const doc = this._doc
        const runtime = doc?.defaultView
        const root = this._root
        if (!(doc instanceof Document) || !(root instanceof HTMLElement)) return null

        let result = null
        this._runWithSuppressedMutations(() => {
            if (this._buildState) {
                this._cancelWarmup()
                this._buildState.stopAfterPageIndex = Math.max(
                    pageIndex,
                    this._buildState.stopAfterPageIndex ?? -1
                )
                this._continueBuilding()
                this._refreshLiveRoot({
                    runtime,
                    root,
                    complete: this.isLayoutComplete(),
                })
                if (!this.isLayoutComplete()) {
                    this._scheduleWarmup()
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
        const pageRecord = this._pageRecords[pageIndex]
        if (!pageRecord || pageRecord.startUnitIndex == null || pageRecord.endUnitIndex == null) return null
        let anchorUnitIndex = pageRecord.startUnitIndex
        const currentAnchorUnitIndex = this._sourceUnitIndexForAnchor(this._currentSourceAnchor)
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
            anchorSentenceIdentifier: this._sentenceIdentifierForUnitIndex(anchorUnitIndex),
            startSourceLocation: this._sourceLocationForUnitIndex(pageRecord.startUnitIndex, 'start'),
            endSourceLocation: this._sourceLocationForUnitIndex(pageRecord.endUnitIndex, 'end'),
            anchorSourceLocation: this._sourceLocationForAnchor(this._currentSourceAnchor)
                || this._sourceLocationForUnitIndex(anchorUnitIndex, 'start'),
            layoutVersion: this._layoutVersion,
        }
    }

    pageIndexForLocation(location) {
        const anchorUnitIndex = this._sourceUnitIndexForLocation(location?.anchorSourceLocation)
            ?? this._unitIndexForSentenceIdentifier(location?.anchorSentenceIdentifier)
            ?? location?.anchorUnitIndex
        if (Number.isFinite(anchorUnitIndex)) {
            return this._unitRecords[anchorUnitIndex]?.pageIndex ?? location?.pageIndex ?? null
        }
        return Number.isFinite(location?.pageIndex) ? location.pageIndex : null
    }

    sourceRangeForLocation(location) {
        const resolvedPageIndex = this.pageIndexForLocation(location)
        const resolvedPageRecord = Number.isFinite(resolvedPageIndex)
            ? this._pageRecords[resolvedPageIndex]
            : null
        if (resolvedPageRecord && resolvedPageRecord.startUnitIndex != null && resolvedPageRecord.endUnitIndex != null && this._sourceDoc) {
            const currentPageRange = this._sourceDoc.createRange()
            this._setRangeBoundary(
                currentPageRange,
                'start',
                this._sourceLocationForUnitIndex(resolvedPageRecord.startUnitIndex, 'start')
            )
            this._setRangeBoundary(
                currentPageRange,
                'end',
                this._sourceLocationForUnitIndex(resolvedPageRecord.endUnitIndex, 'end')
            )
            if (!currentPageRange.collapsed || currentPageRange.toString()?.length) {
                return currentPageRange
            }
        }

        const startSourceLocation = location?.startSourceLocation
        const endSourceLocation = location?.endSourceLocation
        if (startSourceLocation?.sourceNode && endSourceLocation?.sourceNode && this._sourceDoc) {
            const range = this._sourceDoc.createRange()
            this._setRangeBoundary(range, 'start', startSourceLocation)
            this._setRangeBoundary(range, 'end', endSourceLocation)
            if (!range.collapsed || range.toString()?.length) {
                return range
            }
        }
        const startUnitIndex = location?.startUnitIndex
        const endUnitIndex = location?.endUnitIndex
        if (!Number.isFinite(startUnitIndex) || !Number.isFinite(endUnitIndex)) return null
        const startUnit = this._unitRecords[startUnitIndex]
        const endUnit = this._unitRecords[endUnitIndex]
        if (!startUnit || !endUnit || !this._sourceDoc) return null
        const range = this._sourceDoc.createRange()
        this._setRangeBoundary(range, 'start', this._sourceLocationForUnitIndex(startUnitIndex, 'start'))
        this._setRangeBoundary(range, 'end', this._sourceLocationForUnitIndex(endUnitIndex, 'end'))
        if (!range.collapsed || range.toString()?.length) {
            return range
        }
        const pageIndex = resolvedPageIndex
        const pageRecord = resolvedPageRecord
        if (!pageRecord || pageRecord.startUnitIndex == null || pageRecord.endUnitIndex == null) {
            return range
        }
        const pageRange = this._sourceDoc.createRange()
        this._setRangeBoundary(pageRange, 'start', this._sourceLocationForUnitIndex(pageRecord.startUnitIndex, 'start'))
        this._setRangeBoundary(pageRange, 'end', this._sourceLocationForUnitIndex(pageRecord.endUnitIndex, 'end'))
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
        const index = this._sourceUnitIndexForAnchor(anchor)
        return index != null ? (this._unitRecords[index]?.pageIndex ?? 0) : null
    }

    getChunkIdForPage(pageIndex, columnIndex = 0) {
        const pageRecord = this._pageRecords[pageIndex]
        if (!pageRecord) return null
        const chunkRecord = pageRecord.chunkRecords.find(record => record.columnIndex === columnIndex)
            || pageRecord.chunkRecords[0]
        return chunkRecord?.chunkId ?? null
    }

    _effectivePageCount() {
        if (this._pageRecords.length === 0) return 0
        const lastPageRecord = this._pageRecords[this._pageRecords.length - 1]
        const hasOnlyEmptyChunks = lastPageRecord?.chunkRecords?.length > 0
            && lastPageRecord.chunkRecords.every(record => record.startUnitIndex == null)
        if (hasOnlyEmptyChunks && this._buildState) {
            return Math.max(0, this._pageRecords.length - 1)
        }
        return this._pageRecords.length
    }

    _runWithSuppressedMutations(callback) {
        const suppressMutations = this._doc?.defaultView?.manabiWithTrackingStructureMutationSuppressed
            || (fn => fn())
        return suppressMutations(callback)
    }

    _prepareSourceSnapshot({ doc, runtime, root }) {
        const preservedSnapshot = preservedSourceSnapshotForRuntime(runtime)
        const liveRootIsPaginated = rootLooksPaginated(root)
        const currentContentURL = runtime?.manabiCurrentContentURL ?? doc?.URL ?? null
        const preservedSnapshotMatchesCurrentContent =
            !preservedSnapshot?.contentURL || preservedSnapshot.contentURL === currentContentURL

        if (this._sourceContentURL && currentContentURL && this._sourceContentURL !== currentContentURL) {
            logReaderPerf('ebook-layout-source-reset-content-url', {
                previousContentURL: this._sourceContentURL,
                currentContentURL,
                layoutVersion: this._layoutVersion,
            })
            this._normalizedRootHTML = null
            this._sourceDoc = null
            this._sourceRoot = null
            this._unitRecords = []
            this._unitIndicesBySourceNode = new Map()
        }

        if (this._normalizedRootHTML == null) {
            if (liveRootIsPaginated && preservedSnapshot && preservedSnapshotMatchesCurrentContent) {
                this._normalizedRootHTML = preservedSnapshot.rootInnerHTML || null
            } else {
            this._normalizedRootHTML = root.innerHTML
            root.innerHTML = this._normalizedRootHTML
            runtime?.manabiNormalizeLegacyTrackingStructure?.(doc)
            runtime?.manabiBuildSentenceArchive?.(doc)
            this._normalizedRootHTML = root.innerHTML
                const refreshedSnapshot = capturePreservedSourceSnapshot({ doc, root })
                storePreservedSourceSnapshot(runtime, refreshedSnapshot)
                this._sourceContentURL = refreshedSnapshot?.contentURL ?? currentContentURL
            }
            this._sourceDoc = null
            this._sourceRoot = null
        } else if (
            this._sourceDoc instanceof Document
            && this._sourceRoot instanceof HTMLElement
            && this._unitRecords.length > 0
            && (!currentContentURL || this._sourceContentURL === currentContentURL)
        ) {
            logReaderPerf('ebook-layout-source-snapshot-reused', {
                unitCount: this._unitRecords.length,
                layoutVersion: this._layoutVersion,
                contentURL: this._sourceContentURL ?? null,
            })
            return this._unitRecords
        } else {
            if (!liveRootIsPaginated) {
                runtime?.manabiBuildSentenceArchive?.(doc)
                const refreshedSnapshot = capturePreservedSourceSnapshot({ doc, root })
                storePreservedSourceSnapshot(runtime, refreshedSnapshot)
                this._normalizedRootHTML = root.innerHTML
                this._sourceContentURL = refreshedSnapshot?.contentURL ?? currentContentURL
            }
        }

        if (!(this._sourceDoc instanceof Document) || !(this._sourceRoot instanceof HTMLElement)) {
            this._sourceDoc = doc.implementation.createHTMLDocument('')
            if (preservedSnapshot && preservedSnapshotMatchesCurrentContent) {
                applyStoredAttributes(this._sourceDoc.documentElement, preservedSnapshot.documentElementAttributes)
                applyStoredAttributes(this._sourceDoc.body, preservedSnapshot.bodyAttributes)
                this._sourceDoc.body.className = preservedSnapshot.bodyClassName || ''
                this._sourceDoc.body.innerHTML = preservedSnapshot.bodyHTML || ''
                this._sourceContentURL = preservedSnapshot.contentURL ?? currentContentURL
                logReaderPerf('ebook-layout-source-snapshot-restored', {
                    layoutVersion: this._layoutVersion,
                    bodyHTMLLength: preservedSnapshot.bodyHTML?.length ?? 0,
                    capturedAt: preservedSnapshot.capturedAt ?? null,
                    liveRootWasPaginated: liveRootIsPaginated,
                    contentURL: this._sourceContentURL ?? null,
                })
            } else {
                copyAttributes(doc.documentElement, this._sourceDoc.documentElement)
                copyAttributes(doc.body, this._sourceDoc.body)
                this._sourceDoc.body.className = doc.body.className
                this._sourceDoc.body.innerHTML = doc.body.innerHTML
                this._sourceContentURL = currentContentURL
            }
            this._sourceRoot = resolveSectionRoot(this._sourceDoc)
        }

        if (!(this._sourceRoot instanceof HTMLElement)) {
            this._unitRecords = []
            this._unitIndicesBySourceNode = new Map()
            return []
        }

        this._unitRecords = collectEbookChunkUnits(this._sourceRoot)
        this._refreshUnitIndexMap()
        logReaderPerf('ebook-layout-source-snapshot-built', {
            unitCount: this._unitRecords.length,
            layoutVersion: this._layoutVersion,
        })
        return this._unitRecords
    }

    _refreshUnitIndexMap() {
        this._unitIndicesBySourceNode = new Map()
        this._unitRecords.forEach((unit, index) => {
            const indices = this._unitIndicesBySourceNode.get(unit.sourceNode) || []
            indices.push(index)
            this._unitIndicesBySourceNode.set(unit.sourceNode, indices)
        })
    }

    _sourceUnitIndexForAnchor(anchor) {
        const unitCount = this._unitRecords.length
        if (unitCount <= 1) return unitCount === 0 ? null : 0
        if (typeof anchor === 'number') {
            return Math.max(0, Math.min(unitCount - 1, Math.round(anchor * (unitCount - 1))))
        }
        if (!anchor) return null
        if (isRangeLike(anchor)) {
            const directIndex = this._unitIndexForAnchorNode(anchor.startContainer, anchor.startOffset)
            if (directIndex != null) return directIndex
            const sentenceIdentifier = this._sentenceIdentifierForNode(anchor.startContainer)
            return sentenceIdentifier ? this._unitIndexForSentenceIdentifier(sentenceIdentifier) : null
        }
        const directIndex = this._unitIndexForAnchorNode(anchor, 0)
        if (directIndex != null) return directIndex
        const sentenceIdentifier = this._sentenceIdentifierForNode(anchor)
        return sentenceIdentifier ? this._unitIndexForSentenceIdentifier(sentenceIdentifier) : null
    }

    _resolveTargetUnitIndex(anchor) {
        const unitCount = this._unitRecords.length
        if (unitCount <= 1) return 0
        return this._sourceUnitIndexForAnchor(anchor) ?? 0
    }

    _resolveTargetUnitIndexFromLocationOrAnchor(location, anchor) {
        const anchorUnitIndex = this._sourceUnitIndexForAnchor(anchor)
        const anchorSentenceIdentifier = this._sentenceIdentifierForAnchor(anchor)
        if (Number.isFinite(anchorUnitIndex)) {
            const startUnitIndex = location?.startUnitIndex
            const endUnitIndex = location?.endUnitIndex
            if (!Number.isFinite(startUnitIndex)
                || !Number.isFinite(endUnitIndex)
                || (anchorUnitIndex >= startUnitIndex && anchorUnitIndex <= endUnitIndex)) {
                return Math.max(0, Math.min(this._unitRecords.length - 1, anchorUnitIndex))
            }
        }
        const locationAnchorUnitIndex = this._sourceUnitIndexForLocation(location?.anchorSourceLocation)
            ?? this._unitIndexForSentenceIdentifier(location?.anchorSentenceIdentifier)
            ?? location?.anchorUnitIndex
        const locationSentenceIdentifier = location?.anchorSentenceIdentifier
        const locationAnchorIsInRange = Number.isFinite(locationAnchorUnitIndex)
            && locationAnchorUnitIndex >= 0
            && locationAnchorUnitIndex < this._unitRecords.length
        const locationMatchesAnchorSentence = !anchorSentenceIdentifier
            || !locationSentenceIdentifier
            || locationSentenceIdentifier === anchorSentenceIdentifier
            || this._sentenceIdentifierForUnitIndex(locationAnchorUnitIndex) === anchorSentenceIdentifier
        if (locationAnchorIsInRange && locationMatchesAnchorSentence) {
            return Math.max(0, Math.min(this._unitRecords.length - 1, locationAnchorUnitIndex))
        }
        return this._resolveTargetUnitIndex(anchor)
    }

    _createBuildState({
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
        this._removeStagingRoot()
        const root = createStagingRootForLiveRoot(liveRoot)
        if (!(root instanceof HTMLElement)) {
            throw new Error('Unable to create ebook layout staging root.')
        }
        this._stagingRoot = root
        root.innerHTML = ''
        root.classList.add('manabi-page-root')
        applyPageRootLayoutStyles(root)
        root.dataset.manabiLayoutVersion = String(layoutVersion)
        const pageViewportSize = resolvePageViewportSize(root)
        this._pageRecords = []
        updatePageRootLayoutExtent(root, {
            inlineSize: pageViewportSize.inlineSize,
            pageCount: 1,
        })

        const pageNode = doc.createElement('div')
        pageNode.className = 'manabi-page'
        pageNode.dataset.manabiPageIndex = '0'
        applyPageLayoutStyles(pageNode, {
            ...pageViewportSize,
            pageIndex: 0,
        })
        root.appendChild(pageNode)

        const pageRecord = {
            pageIndex: 0,
            pageNode,
            startUnitIndex: null,
            endUnitIndex: null,
            chunkRecords: [],
        }
        this._pageRecords.push(pageRecord)

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
            pageViewportSize,
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

    _assignUnitToCurrentChunk(state, unitIndex) {
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
                this._unitContainsSourceLocation(unit, state.targetSourceLocation)
                || unitIndex === state.targetUnitIndex
            )
        ) {
            state.stopAfterPageIndex = state.pageIndex
        }
    }

    _advanceChunk(state) {
        state.columnIndex += 1
        if (state.columnIndex >= state.columnCount) {
            state.pageIndex += 1
            state.columnIndex = 0
            state.pageNode = state.doc.createElement('div')
            state.pageNode.className = 'manabi-page'
            state.pageNode.dataset.manabiPageIndex = String(state.pageIndex)
            applyPageLayoutStyles(state.pageNode, {
                ...state.pageViewportSize,
                pageIndex: state.pageIndex,
            })
            state.root.appendChild(state.pageNode)
            updatePageRootLayoutExtent(state.root, {
                inlineSize: state.pageViewportSize.inlineSize,
                pageCount: state.pageIndex + 1,
            })
            state.pageRecord = {
                pageIndex: state.pageIndex,
                pageNode: state.pageNode,
                startUnitIndex: null,
                endUnitIndex: null,
                chunkRecords: [],
            }
            this._pageRecords.push(state.pageRecord)
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

    _continueBuilding() {
        const state = this._buildState
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
                    if (!shouldDelayChunkOverflowBoundary(state.chunkBody, state.appendState, unit)) {
                        allowOversizeChunkOverflow(state.chunkNode, state.chunkBody)
                    }
                }
                this._assignUnitToCurrentChunk(state, state.unitIndex)
                state.unitIndex += 1
                continue
            }

            if (!chunkBodyHasOverflow(state.chunkBody, state.metrics.vertical)) {
                this._assignUnitToCurrentChunk(state, state.unitIndex)
                state.unitIndex += 1
                continue
            }

            if (shouldDelayChunkOverflowBoundary(state.chunkBody, state.appendState, unit)) {
                this._assignUnitToCurrentChunk(state, state.unitIndex)
                state.unitIndex += 1
                continue
            }

            revertChunkUnit(state.appendState, appendRecord)
            const splitUnits = splitChunkUnitForFit(unit)
            if (splitUnits && splitUnits.length > 1) {
                state.units.splice(state.unitIndex, 1, ...splitUnits)
                continue
            }
            this._advanceChunk(state)
        }

        this._refreshUnitIndexMap()
        if (state.unitIndex >= state.units.length) {
            this._trimTrailingEmptyPage()
            this._buildState = null
            return
        }
        this._buildState = state
    }

    _trimTrailingEmptyPage() {
        const lastPageRecord = this._pageRecords[this._pageRecords.length - 1]
        if (!lastPageRecord?.chunkRecords?.length) return
        const hasOnlyEmptyChunks = lastPageRecord.chunkRecords.every(record => record.startUnitIndex == null)
        if (!hasOnlyEmptyChunks) return
        lastPageRecord.pageNode.remove()
        this._pageRecords.pop()
    }

    _removeStagingRoot() {
        this._stagingRoot?.remove?.()
        this._stagingRoot = null
    }

    _commitStagingRootToLiveRoot({ liveRoot, stagingRoot }) {
        if (!(liveRoot instanceof HTMLElement) || !(stagingRoot instanceof HTMLElement)) return
        const commitStart = perfNow()
        liveRoot.className = stagingRoot.className
        liveRoot.dataset.manabiLayoutVersion = stagingRoot.dataset.manabiLayoutVersion || ''
        liveRoot.style.cssText = stagingRoot.style.cssText
        liveRoot.innerHTML = stagingRoot.innerHTML
        logReaderPerf('ebook-layout-commit-live-root', {
            childCount: liveRoot.childElementCount,
            htmlLength: liveRoot.innerHTML.length,
            commitInnerHTMLDurationMs: Math.round((perfNow() - commitStart) * 100) / 100,
        })
    }

    _syncChunkSourceMetadata(root = null) {
        const liveRoot = root instanceof HTMLElement ? root : null
        for (const pageRecord of this._pageRecords) {
            for (const chunkRecord of pageRecord.chunkRecords || []) {
                let chunkNode = chunkRecord?.chunkNode
                const chunkId = chunkNode?.dataset?.manabiChunkId
                if (liveRoot instanceof HTMLElement && chunkId) {
                    const liveChunkNode = liveRoot.querySelector(
                        `.manabi-page-column-chunk[data-manabi-chunk-id="${chunkId}"]`
                    )
                    if (liveChunkNode instanceof HTMLElement) {
                        chunkNode = liveChunkNode
                        chunkRecord.chunkNode = liveChunkNode
                    }
                }
                if (!(chunkNode instanceof HTMLElement)) continue
                const startUnitIndex = chunkRecord.startUnitIndex
                const endUnitIndex = chunkRecord.endUnitIndex
                if (!Number.isFinite(startUnitIndex) || !Number.isFinite(endUnitIndex)) continue
                chunkNode.dataset.manabiSourceStartUnitIndex = String(startUnitIndex)
                chunkNode.dataset.manabiSourceEndUnitIndex = String(endUnitIndex)
                const startSentenceIdentifier = this._sentenceIdentifierForUnitIndex(startUnitIndex)
                const endSentenceIdentifier = this._sentenceIdentifierForUnitIndex(endUnitIndex)
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

    _scheduleWarmup() {
        this._cancelWarmup()
        if (!this._buildState || !(this._doc?.defaultView instanceof Window)) return
        const token = ++this._warmupToken
        logReaderPerf('ebook-layout-warmup-scheduled', {
            layoutVersion: this._layoutVersion,
            pageCount: this.pageCount(),
        })
        this._warmupTimer = this._doc.defaultView.setTimeout(() => {
            this._warmupTimer = null
            this._warmRemainingPages(token)
        }, WARMUP_DELAY_MS)
    }

    _cancelWarmup() {
        if (this._warmupTimer != null && this._doc?.defaultView) {
            this._doc.defaultView.clearTimeout(this._warmupTimer)
        }
        this._warmupTimer = null
        this._warmupToken += 1
    }

    _warmRemainingPages(token) {
        if (token !== this._warmupToken || !this._buildState) return
        const doc = this._doc
        const runtime = doc?.defaultView
        const root = this._root
        if (!(doc instanceof Document) || !(root instanceof HTMLElement)) return

        this._runWithSuppressedMutations(() => {
            if (!this._buildState) return
            const warmupStart = perfNow()
            const pageCountBefore = this.pageCount()
            const nextVisiblePageIndex = Math.max(0, this.pageCount() + WARMUP_PAGE_BATCH - 1)
            this._buildState.stopAfterPageIndex = Math.max(
                nextVisiblePageIndex,
                this._buildState.stopAfterPageIndex ?? -1
            )
            this._continueBuilding()
            this._commitStagingRootToLiveRoot({
                liveRoot: root,
                stagingRoot: this._buildState?.root ?? this._stagingRoot,
            })
            this._refreshLiveRoot({
                runtime,
                root,
                complete: this.isLayoutComplete(),
            })
            logReaderPerf('ebook-layout-warmup-batch', {
                layoutVersion: this._layoutVersion,
                pageCountBefore,
                pageCountAfter: this.pageCount(),
                builtPageCount: Math.max(0, this.pageCount() - pageCountBefore),
                durationMs: Math.round((perfNow() - warmupStart) * 100) / 100,
                layoutComplete: this.isLayoutComplete(),
            })
            if (!this.isLayoutComplete()) {
                this._scheduleWarmup()
            } else {
                this._removeStagingRoot()
                logReaderPerf('ebook-layout-warmup-complete', {
                    layoutVersion: this._layoutVersion,
                    pageCount: this.pageCount(),
                })
            }
        })
    }

    _refreshLiveRoot({ runtime, root, complete }) {
        this._syncChunkSourceMetadata(root)
        const chunkSections = Array.from(root?.querySelectorAll?.('.manabi-page-column-chunk') || [])
        chunkSections.forEach((sectionNode, sectionIndex) => {
            if (!(sectionNode instanceof HTMLElement)) return
            sectionNode.classList.add('manabi-tracking-section')
            runtime?.manabiCreateTrackingSectionChrome?.(sectionNode, sectionIndex, {
                includePreviewUI: false,
            })
            runtime?.manabiEnsureTrackingMarker?.(sectionNode)
        })
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
                vertical: this._buildState?.metrics?.vertical
                    ?? root.ownerDocument?.body?.classList?.contains?.('reader-vertical-writing') === true,
                isReaderMode: true,
                isEbook: true,
            })
        } catch (_error) {}

        if (this._doc?.documentElement) {
            this._doc.documentElement.dataset.manabiLayoutComplete = complete ? 'true' : 'false'
        }
        if (complete) {
            try {
                this._doc?.defaultView?.dispatchEvent?.(new CustomEvent('manabi-ebook-layout-complete', {
                    detail: {
                        layoutVersion: this._layoutVersion,
                        pageCount: this.pageCount(),
                    },
                }))
            } catch (_error) {}
        }
    }

    _normalizeSourceAnchor(anchor, fallbackPageIndex = 0) {
        const sourceDoc = this._sourceDoc
        const anchorDoc = anchor?.startContainer?.getRootNode?.() ?? anchor?.ownerDocument ?? null
        if (sourceDoc && anchorDoc === sourceDoc) {
            return anchor
        }
        return this.sourceRangeForPage(fallbackPageIndex)
            || this.sourceRangeForPage(0)
            || this._currentSourceAnchor
    }

    _sourceAnchorForUnitIndex(unitIndex) {
        return this._sourceAnchorForLocation(this._sourceLocationForUnitIndex(unitIndex, 'start'))
    }

    _sourceAnchorForSentenceIdentifier(sentenceIdentifier) {
        return this._sourceAnchorForLocation(this._sourceLocationForSentenceIdentifier(sentenceIdentifier))
    }

    _sourceLocationForAnchor(anchor) {
        if (!anchor) return null
        if (isRangeLike(anchor)) {
            return this._sourceLocationForBoundaryNode(anchor.startContainer, anchor.startOffset)
                || this._sourceLocationForNode(anchor.startContainer)
        }
        return this._sourceLocationForNode(anchor)
    }

    _sourceLocationForUnitIndex(unitIndex, edge = 'start') {
        const unit = this._unitRecords[unitIndex]
        if (!unit) return null
        return {
            sourceNode: unit.sourceNode,
            sourceOffset: unit.type === 'text'
                ? (edge === 'end' ? unit.sourceEndOffset : unit.sourceStartOffset)
                : 0,
            edge,
        }
    }

    _sourceLocationForSentenceIdentifier(sentenceIdentifier) {
        const unitIndex = this._unitIndexForSentenceIdentifier(sentenceIdentifier)
        return Number.isFinite(unitIndex)
            ? this._sourceLocationForUnitIndex(unitIndex, 'start')
            : null
    }

    _sourceAnchorForLocation(location) {
        const sourceNode = location?.sourceNode
        if (!sourceNode || !this._sourceDoc) return null
        const range = this._sourceDoc.createRange()
        this._setRangeBoundary(range, 'start', location)
        range.collapse(true)
        return range
    }

    _unitContainsSourceLocation(unit, location) {
        if (!unit || !location?.sourceNode || unit.sourceNode !== location.sourceNode) {
            return false
        }
        if (unit.type !== 'text') {
            return true
        }
        const sourceOffset = Number.isFinite(location.sourceOffset) ? location.sourceOffset : 0
        return sourceOffset >= unit.sourceStartOffset && sourceOffset < unit.sourceEndOffset
    }

    _sentenceIdentifierForNode(node) {
        if (!node) return null
        const sentenceNode = node.nodeType === Node.ELEMENT_NODE
            ? node.closest?.('manabi-sentence')
            : node.parentElement?.closest?.('manabi-sentence')
        return sentenceNode?.dataset?.sentenceIdentifier || null
    }

    _sentenceIdentifierForAnchor(anchor) {
        if (!anchor) return null
        if (isRangeLike(anchor)) {
            return this._sentenceIdentifierForNode(anchor.startContainer)
        }
        return this._sentenceIdentifierForNode(anchor)
    }

    _sentenceIdentifierForUnitIndex(unitIndex) {
        const unit = this._unitRecords[unitIndex]
        return this._sentenceIdentifierForNode(unit?.sourceNode)
    }

    _sourceUnitIndexForLocation(location) {
        const anchor = this._sourceAnchorForLocation(location)
        return this._sourceUnitIndexForAnchor(anchor)
    }

    _setRangeBoundary(range, edge, location) {
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

    _sourceLocationForBoundaryNode(node, offset = 0) {
        if (!node) return null
        if (node.nodeType === Node.TEXT_NODE) {
            return {
                sourceNode: node,
                sourceOffset: Math.max(0, Math.min(node.nodeValue?.length ?? 0, offset)),
                edge: 'start',
            }
        }
        if (node.nodeType !== Node.ELEMENT_NODE) {
            return this._sourceLocationForNode(node)
        }
        const childNodes = Array.from(node.childNodes || [])
        const preferredChild = childNodes[offset] || childNodes[childNodes.length - 1] || null
        return this._sourceLocationForNode(preferredChild)
            || this._sourceLocationForNode(node)
    }

    _sourceLocationForNode(node) {
        if (!node) return null
        if (node.nodeType === Node.TEXT_NODE) {
            return {
                sourceNode: node,
                sourceOffset: 0,
                edge: 'start',
            }
        }
        if (node.nodeType !== Node.ELEMENT_NODE) return null
        const directUnitIndices = this._unitIndicesBySourceNode.get(node)
        if (directUnitIndices?.length) {
            return this._sourceLocationForUnitIndex(directUnitIndices[0], 'start')
        }
        const walker = node.ownerDocument?.createTreeWalker?.(
            node,
            NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT
        )
        let current = walker?.currentNode
        while (current) {
            if (current !== node) {
                const currentUnitIndices = this._unitIndicesBySourceNode.get(current)
                if (currentUnitIndices?.length) {
                    return this._sourceLocationForUnitIndex(currentUnitIndices[0], 'start')
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

    _unitIndexForSentenceIdentifier(sentenceIdentifier) {
        if (!sentenceIdentifier) return null
        for (let index = 0; index < this._unitRecords.length; index += 1) {
            if (this._sentenceIdentifierForUnitIndex(index) === sentenceIdentifier) {
                return index
            }
        }
        return null
    }

    _unitIndexForAnchorNode(node, offset = 0) {
        if (!node) return null
        if (node.nodeType === Node.TEXT_NODE) {
            const indices = this._unitIndicesBySourceNode.get(node)
            if (indices?.length) {
                for (const index of indices) {
                    const unit = this._unitRecords[index]
                    if (unit.type === 'text' && offset < unit.sourceEndOffset) {
                        return index
                    }
                }
                return indices[indices.length - 1]
            }
        }
        if (node.nodeType === Node.ELEMENT_NODE) {
            const directIndices = this._unitIndicesBySourceNode.get(node)
            if (directIndices?.length) return directIndices[0]
            const walker = node.ownerDocument?.createTreeWalker?.(
                node,
                NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT
            )
            let current = walker?.currentNode
            while (current) {
                const currentIndices = this._unitIndicesBySourceNode.get(current)
                if (currentIndices?.length) return currentIndices[0]
                current = walker.nextNode()
            }
        }
        let ancestor = node.parentNode
        while (ancestor) {
            const indices = this._unitIndicesBySourceNode.get(ancestor)
            if (indices?.length) return indices[0]
            ancestor = ancestor.parentNode
        }
        return null
    }
}
