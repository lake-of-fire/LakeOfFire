const parseViewport = str => str
    ?.split(/[,;\s]/) // NOTE: technically, only the comma is valid
    ?.filter(x => x)
    ?.map(x => x.split('=').map(x => x.trim()))

const normalizedViewport = value => {
    const width = parseFloat(value?.width)
    const height = parseFloat(value?.height)
    return Number.isFinite(width) && width > 0
        && Number.isFinite(height) && height > 0
        ? { width, height }
        : null
}

const parsedViewport = value => {
    try {
        return normalizedViewport(Object.fromEntries(parseViewport(value) ?? []))
    } catch (_error) {
        return null
    }
}

const getViewport = (doc, viewport) => {
    // use `viewBox` for SVG
    if (doc.documentElement?.nodeName === 'svg') {
        const [, , width, height] = doc.documentElement
            .getAttribute('viewBox')?.trim()?.split(/\s+/) ?? []
        const svgViewport = normalizedViewport({ width, height })
        if (svgViewport) return svgViewport
    }

    // get `viewport` `meta` element. Invalid web-style values such as
    // `width=device-width` must not outrank a valid rendition fallback.
    const metadataViewport = parsedViewport(doc.querySelector('meta[name="viewport"]')
        ?.getAttribute('content'))
    if (metadataViewport) return metadataViewport

    // fallback to book's viewport
    const bookViewport = typeof viewport === 'string'
        ? parsedViewport(viewport)
        : normalizedViewport(viewport)
    if (bookViewport) return bookViewport

    // if no viewport (possibly with image directly in spine), get image size
    const img = doc.querySelector('img')
    const imageViewport = normalizedViewport({
        width: img?.naturalWidth,
        height: img?.naturalHeight,
    })
    if (imageViewport) return imageViewport

    // just show *something*, i guess...
    console.warn(new Error('Missing viewport properties'))
    return { width: 1000, height: 2000 }
}

class FixedLayoutNavigationCancelled extends Error {
    constructor(reason) {
        super(reason)
        this.name = 'FixedLayoutNavigationCancelled'
        this.reason = reason
    }
}

const fixedLayoutNonOwningResult = (reason, { superseded = true } = {}) => ({
    ignored: true,
    ...(superseded ? { superseded: true } : {}),
    reason,
})

export class FixedLayout extends HTMLElement {
    #root = this.attachShadow({ mode: 'closed' })
    #resizeObserver = new ResizeObserver(() => this.#render())
    #spreads
    #index = -1
    defaultViewport
    spread
    #portrait = false
    #left
    #right
    #center
    #side
    #sectionResources = new Map()
    #activeSectionLeases = []
    #activeContainer = null
    #frameDocumentStates = new WeakMap()
    #navigationTransaction = null
    #destroyed = false
    constructor() {
        super()

        const style = document.createElement('style')
        style.textContent = `:host {
            width: 100%;
            height: 100%;
            display: flex;
            justify-content: center;
            align-items: center;
        }`
        this.#root.append(style)

        this.#resizeObserver.observe(this)
    }
    #cancelNavigation(transaction, reason) {
        if (!transaction || transaction.cancelled) return
        transaction.cancelled = true
        transaction.reason = reason
        for (const listener of [...transaction.cancellationListeners]) {
            try { listener(reason) } catch (_error) {}
        }
        transaction.cancellationListeners.clear()
        transaction.container?.remove()
        transaction.container = null
    }
    #beginNavigation(options = {}) {
        if (
            options.ignoreIfNavigationInFlight === true
            && this.#navigationTransaction
        ) {
            return null
        }
        this.#cancelNavigation(
            this.#navigationTransaction,
            'fixedLayoutNavigationSuperseded'
        )
        const relocationID = typeof options.relocationID === 'string'
            && options.relocationID.length > 0
            ? options.relocationID
            : null
        const transaction = {
            cancelled: this.#destroyed,
            reason: this.#destroyed ? 'fixedLayoutDestroyed' : null,
            cancellationListeners: new Set(),
            container: null,
            relocationID,
        }
        this.#navigationTransaction = transaction
        return transaction
    }
    async #runNavigation(operation, options = {}) {
        const transaction = this.#beginNavigation(options)
        if (!transaction) {
            return fixedLayoutNonOwningResult('rendererNavigationInFlight', {
                superseded: false,
            })
        }
        try {
            return await operation(transaction)
        } finally {
            this.#finishNavigation(transaction)
        }
    }
    get navigationInFlight() {
        return this.#navigationTransaction !== null
    }
    #finishNavigation(transaction) {
        transaction?.cancellationListeners?.clear?.()
        if (this.#navigationTransaction === transaction) {
            this.#navigationTransaction = null
        }
    }
    #isCurrentNavigation(transaction) {
        return !this.#destroyed
            && !transaction?.cancelled
            && this.#navigationTransaction === transaction
    }
    #navigationCancellationError(transaction) {
        return new FixedLayoutNavigationCancelled(
            transaction?.reason ?? 'fixedLayoutNavigationSuperseded'
        )
    }
    #requireCurrentNavigation(transaction) {
        if (!this.#isCurrentNavigation(transaction)) {
            throw this.#navigationCancellationError(transaction)
        }
    }
    #navigationResultForError(error) {
        return error instanceof FixedLayoutNavigationCancelled
            ? fixedLayoutNonOwningResult(error.reason)
            : false
    }
    #sectionResource(section) {
        const existing = this.#sectionResources.get(section)
        if (existing) return existing
        const resource = {
            section,
            references: 0,
            settled: false,
            src: null,
            promise: null,
        }
        resource.promise = Promise.resolve()
            .then(() => section.load())
            .then(
                src => {
                    if (!src) {
                        throw new Error('Fixed-layout section returned no source')
                    }
                    resource.settled = true
                    resource.src = src
                    if (resource.references === 0) {
                        this.#disposeSectionResource(resource)
                    }
                    return { type: 'loaded', src }
                },
                error => {
                    resource.settled = true
                    if (this.#sectionResources.get(section) === resource) {
                        this.#sectionResources.delete(section)
                    }
                    return { type: 'failed', error }
                }
            )
            .catch(error => {
                resource.settled = true
                if (this.#sectionResources.get(section) === resource) {
                    this.#sectionResources.delete(section)
                }
                return { type: 'failed', error }
            })
        this.#sectionResources.set(section, resource)
        return resource
    }
    #disposeSectionResource(resource) {
        if (!resource?.settled || resource.references > 0 || !resource.src) return
        if (this.#sectionResources.get(resource.section) === resource) {
            this.#sectionResources.delete(resource.section)
        }
        resource.src = null
        try {
            resource.section?.unload?.()
        } catch (_error) {}
    }
    #releaseSectionLease(lease) {
        if (!lease || lease.released) return
        lease.released = true
        const resource = lease.resource
        resource.references = Math.max(0, resource.references - 1)
        this.#disposeSectionResource(resource)
    }
    #releaseSectionLeases(leases) {
        for (const lease of leases ?? []) this.#releaseSectionLease(lease)
    }
    async #acquireSection(section, transaction) {
        const resource = this.#sectionResource(section)
        resource.references += 1
        const lease = { resource, released: false }
        let cancelListener
        const cancellation = new Promise(resolve => {
            cancelListener = reason => resolve({ type: 'cancelled', reason })
            transaction.cancellationListeners.add(cancelListener)
            if (transaction.cancelled) cancelListener(transaction.reason)
        })
        const outcome = await Promise.race([resource.promise, cancellation])
        transaction.cancellationListeners.delete(cancelListener)
        if (outcome.type === 'cancelled') {
            this.#releaseSectionLease(lease)
            throw new FixedLayoutNavigationCancelled(outcome.reason)
        }
        if (outcome.type === 'failed') {
            this.#releaseSectionLease(lease)
            throw outcome.error
        }
        if (!this.#isCurrentNavigation(transaction)) {
            this.#releaseSectionLease(lease)
            throw this.#navigationCancellationError(transaction)
        }
        return { src: outcome.src, lease }
    }
    async #createFrame({ index, src }, container, transaction) {
        this.#requireCurrentNavigation(transaction)
        const element = document.createElement('div')
        const iframe = document.createElement('iframe')
        element.append(iframe)
        Object.assign(iframe.style, {
            border: '0',
            display: 'none',
            overflow: 'hidden',
        })
        // `allow-scripts` is needed for events because of WebKit bug
        // https://bugs.webkit.org/show_bug.cgi?id=218086
        iframe.setAttribute('sandbox', 'allow-same-origin allow-scripts')
        iframe.setAttribute('scrolling', 'no')
        iframe.setAttribute('part', 'filter')
        iframe.dataset.index = String(index)
        container.append(element)
        if (!src) return { blank: true, element, iframe }
        return new Promise((resolve, reject) => {
            let settled = false
            const finish = () => {
                if (settled) return false
                settled = true
                iframe.removeEventListener('load', onload)
                iframe.removeEventListener('error', onerror)
                transaction.cancellationListeners.delete(oncancel)
                return true
            }
            const fail = error => {
                if (!finish()) return
                reject(error)
            }
            const oncancel = reason => fail(new FixedLayoutNavigationCancelled(reason))
            const onerror = () => fail(
                new Error(`Failed to load fixed-layout frame for section ${index}`)
            )
            const onload = () => {
                if (!finish()) return
                try {
                    this.#requireCurrentNavigation(transaction)
                    const doc = iframe.contentDocument
                    if (!doc) {
                        throw new Error(`Missing fixed-layout document for section ${index}`)
                    }
                    const { width, height } = getViewport(doc, this.defaultViewport)
                    resolve({
                        element,
                        iframe,
                        doc,
                        index,
                        width,
                        height,
                    })
                } catch (error) {
                    reject(error)
                }
            }
            transaction.cancellationListeners.add(oncancel)
            if (transaction.cancelled) {
                oncancel(transaction.reason)
                return
            }
            iframe.addEventListener('load', onload)
            iframe.addEventListener('error', onerror)
            iframe.src = src
        })
    }
    #layoutFrames({ left, right, center }, side) {
        if (!side) return null
        if (!center && (!left || !right)) return null
        const leftFrame = left ?? {}
        const rightFrame = center ?? right
        const target = side === 'left' ? leftFrame : rightFrame
        const { width, height } = this.getBoundingClientRect()
        const portrait = this.spread !== 'both' && this.spread !== 'portrait'
            && height > width
        const blankWidth = leftFrame.width ?? rightFrame.width
        const blankHeight = leftFrame.height ?? rightFrame.height

        const scale = portrait
            ? Math.min(
                width / (target.width ?? blankWidth),
                height / (target.height ?? blankHeight))
            : Math.min(
                width / ((leftFrame.width ?? blankWidth) + (rightFrame.width ?? blankWidth)),
                height / Math.max(
                    leftFrame.height ?? blankHeight,
                    rightFrame.height ?? blankHeight))

        const transform = frame => {
            const { element, iframe, width: frameWidth, height: frameHeight } = frame
            Object.assign(iframe.style, {
                width: `${frameWidth}px`,
                height: `${frameHeight}px`,
                transform: `scale(${scale})`,
                transformOrigin: 'top left',
                display: 'block',
            })
            Object.assign(element.style, {
                width: `${(frameWidth ?? blankWidth) * scale}px`,
                height: `${(frameHeight ?? blankHeight) * scale}px`,
                overflow: 'hidden',
                display: 'block',
            })
            if (portrait && frame !== target) {
                element.style.display = 'none'
            }
        }
        if (center) {
            transform(center)
        } else {
            transform(leftFrame)
            transform(rightFrame)
        }
        return { portrait }
    }
    #render(side = this.#side) {
        const layout = this.#layoutFrames({
            left: this.#left,
            right: this.#right,
            center: this.#center,
        }, side)
        if (!layout) return false
        this.#side = side
        this.#portrait = layout.portrait
        return true
    }
    #commitSectionLeases(leases) {
        const previousLeases = this.#activeSectionLeases
        this.#activeSectionLeases = [...leases]
        this.#releaseSectionLeases(previousLeases)
    }
    #frameDocumentDetail(frame) {
        if (frame?.blank || !frame?.doc || !Number.isInteger(frame?.index)) return null
        return {
            doc: frame.doc,
            index: frame.index,
            location: frame.doc?.location?.href ?? null,
        }
    }
    #rememberFrameDocument(frame) {
        const detail = this.#frameDocumentDetail(frame)
        if (!detail) return null
        const state = { detail, committed: false }
        this.#frameDocumentStates.set(frame, state)
        return state
    }
    #publishFrameLoadAndCommit(frame, committedContainer) {
        const state = this.#frameDocumentStates.get(frame)
            ?? this.#rememberFrameDocument(frame)
        if (!state) return false
        this.dispatchEvent(new CustomEvent('load', {
            detail: state.detail,
        }))
        const isStillActive = this.#activeContainer === committedContainer
            && [this.#center, this.#left, this.#right].includes(frame)
            && this.#frameDocumentStates.get(frame) === state
        if (!isStillActive) return false
        state.committed = true
        this.dispatchEvent(new CustomEvent('document-committed', {
            detail: state.detail,
        }))
        return true
    }
    #unloadFrameDocument(frame, reason = 'fixed-layout.frame.unload') {
        const state = frame ? this.#frameDocumentStates.get(frame) : null
        if (!state) return false
        this.#frameDocumentStates.delete(frame)
        this.dispatchEvent(new CustomEvent('document-unload', {
            detail: {
                ...state.detail,
                committed: state.committed === true,
                reason,
            },
        }))
        return true
    }
    #unloadFrameDocuments(frames, reason) {
        for (const frame of frames ?? []) this.#unloadFrameDocument(frame, reason)
    }
    #createSpreadContainer() {
        const container = document.createElement('div')
        Object.assign(container.style, {
            display: 'flex',
            justifyContent: 'center',
            alignItems: 'center',
            width: '100%',
            height: '100%',
            position: 'absolute',
            inset: '0',
            visibility: 'hidden',
            pointerEvents: 'none',
        })
        this.#root.append(container)
        return container
    }
    async #showSpread({ left, right, center, side, index }, transaction) {
        let container
        let nextLeft = null
        let nextRight = null
        let nextCenter = null
        let layout
        const resolvedSide = center ? 'center' : side
        try {
            this.#requireCurrentNavigation(transaction)
            container = this.#createSpreadContainer()
            transaction.container = container
            if (center) {
                nextCenter = await this.#createFrame(center, container, transaction)
            } else {
                nextLeft = await this.#createFrame(left, container, transaction)
                nextRight = await this.#createFrame(right, container, transaction)
            }
            this.#requireCurrentNavigation(transaction)
            layout = this.#layoutFrames({
                left: nextLeft,
                right: nextRight,
                center: nextCenter,
            }, resolvedSide)
            if (!layout) throw new Error('Incomplete fixed-layout spread')
            this.#requireCurrentNavigation(transaction)
        } catch (error) {
            try { container?.remove() } catch (_cleanupError) {}
            if (transaction.container === container) transaction.container = null
            if (error instanceof FixedLayoutNavigationCancelled) throw error
            return false
        }

        // Everything that can fail before visible mutation completed in the
        // staging container. Commit the complete spread as one active unit.
        const previousContainer = this.#activeContainer
        const previousFrames = [this.#center, this.#left, this.#right].filter(Boolean)
        this.#activeContainer = container
        transaction.container = null
        this.#left = nextLeft
        this.#right = nextRight
        this.#center = nextCenter
        this.#side = resolvedSide
        this.#portrait = layout.portrait
        this.#index = index
        Object.assign(container.style, {
            position: '',
            inset: '',
            visibility: '',
            pointerEvents: '',
        })
        for (const frame of [nextCenter, nextLeft, nextRight]) {
            this.#rememberFrameDocument(frame)
        }
        this.#unloadFrameDocuments(previousFrames, 'fixed-layout.spread.replaced')
        previousContainer?.remove()
        return true
    }
    #goLeft() {
        if (this.#center || this.#left?.blank) return false
        if (this.#portrait && this.#left?.element?.style?.display === 'none') {
            this.#render('left')
            return true
        }
        return false
    }
    #goRight() {
        if (this.#center || this.#right?.blank) return false
        if (this.#portrait && this.#right?.element?.style?.display === 'none') {
            this.#render('right')
            return true
        }
        return false
    }
    open(book) {
        this.#cancelNavigation(this.#navigationTransaction, 'fixedLayoutNavigationReset')
        this.#navigationTransaction = null
        this.#releaseSectionLeases(this.#activeSectionLeases)
        this.#activeSectionLeases = []
        this.#unloadFrameDocuments(
            [this.#center, this.#left, this.#right].filter(Boolean),
            'fixed-layout.open.reset'
        )
        this.#activeContainer?.remove()
        this.#activeContainer = null
        this.#left = null
        this.#right = null
        this.#center = null
        this.#side = null
        this.#index = -1
        this.#destroyed = false
        this.#resizeObserver.observe(this)
        this.book = book
        const { rendition } = book
        this.spread = rendition?.spread
        this.defaultViewport = rendition?.viewport

        const rtl = book.dir === 'rtl'
        const ltr = !rtl
        this.rtl = rtl

        if (rendition?.spread === 'none')
            this.#spreads = book.sections.map(section => ({ center: section }))
        else this.#spreads = book.sections.reduce((arr, section) => {
            const last = arr[arr.length - 1]
            const { linear, pageSpread } = section
            if (linear === 'no') return arr
            const newSpread = () => {
                const spread = {}
                arr.push(spread)
                return spread
            }
            if (pageSpread === 'center') newSpread().center = section
            else if (pageSpread === 'left') {
                const spread = last.center || last.left || ltr ? newSpread() : last
                spread.left = section
            }
            else if (pageSpread === 'right') {
                const spread = last.center || last.right || rtl ? newSpread() : last
                spread.right = section
            }
            else if (ltr) {
                if (last.center || last.right) newSpread().left = section
                else if (last.left) last.right = section
                else last.left = section
            }
            else {
                if (last.center || last.left) newSpread().right = section
                else if (last.right) last.left = section
                else last .right = section
            }
            return arr
        }, [{}]).filter(spread => spread.center || spread.left || spread.right)
    }
    get index() {
        const spread = this.#spreads[this.#index]
        const section = spread?.center ?? (this.#side === 'left'
            ? spread.left ?? spread.right : spread.right ?? spread.left)
        return this.book.sections.indexOf(section)
    }
    get currentIndex() {
        return this.index
    }
    #reportLocation(reason, relocationID = null) {
        const detail = {
            reason,
            range: null,
            index: this.index,
            fraction: 0,
            size: 1,
        }
        if (typeof relocationID === 'string' && relocationID.length > 0) {
            detail.relocationID = relocationID
        }
        this.dispatchEvent(new CustomEvent('relocate', { detail }))
    }
    getSpreadOf(section) {
        const spreads = this.#spreads
        for (let index = 0; index < spreads.length; index++) {
            const { left, right, center } = spreads[index]
            if (left === section) return { index, side: 'left' }
            if (right === section) return { index, side: 'right' }
            if (center === section) return { index, side: 'center' }
        }
    }
    #resolvedNavigationSideForSpread(spread, requestedSide) {
        if (spread?.center) return 'center'
        if (requestedSide === 'left' && spread?.left) return 'left'
        if (requestedSide === 'right' && spread?.right) return 'right'
        if (spread?.left) return 'left'
        if (spread?.right) return 'right'
        return null
    }
    #adjacentLinearSpreadIndex(direction) {
        for (
            let index = this.#index + direction;
            index >= 0 && index < this.#spreads.length;
            index += direction
        ) {
            const spread = this.#spreads[index]
            const sections = [spread?.center, spread?.left, spread?.right]
                .filter(Boolean)
            if (sections.some(section => section.linear !== 'no')) return index
        }
        return null
    }
    async #goToSpread(index, side, reason, transaction) {
        if (!this.#isCurrentNavigation(transaction)) {
            return fixedLayoutNonOwningResult(
                transaction?.reason ?? 'fixedLayoutNavigationSuperseded'
            )
        }
        if (!Number.isInteger(index) || index < 0 || index >= this.#spreads.length) return false
        const spread = this.#spreads[index]
        const hasRequestedSide = spread?.center
            ? side === 'center'
            : (side === 'left' ? !!spread.left : side === 'right' ? !!spread.right : false)
        if (!hasRequestedSide) return false
        const resolvedSide = side
        if (index === this.#index) {
            const previousSectionIndex = this.index
            this.#render(resolvedSide)
            const moved = this.index !== previousSectionIndex
            this.#finishNavigation(transaction)
            if (moved) this.#reportLocation(reason, transaction.relocationID)
            return moved
        }

        let preparedSpread
        const sectionLeases = []
        try {
            if (spread.center) {
                const sectionIndex = this.book.sections.indexOf(spread.center)
                const { src, lease } = await this.#acquireSection(spread.center, transaction)
                sectionLeases.push(lease)
                preparedSpread = { center: { index: sectionIndex, src } }
            } else {
                const indexL = this.book.sections.indexOf(spread.left)
                const indexR = this.book.sections.indexOf(spread.right)
                let srcL = null
                let srcR = null
                if (spread.left) {
                    const acquired = await this.#acquireSection(spread.left, transaction)
                    srcL = acquired.src
                    sectionLeases.push(acquired.lease)
                }
                if (spread.right) {
                    const acquired = await this.#acquireSection(spread.right, transaction)
                    srcR = acquired.src
                    sectionLeases.push(acquired.lease)
                }
                preparedSpread = {
                    left: { index: indexL, src: srcL },
                    right: { index: indexR, src: srcR },
                    side: resolvedSide,
                }
            }

            const displayed = await this.#showSpread({
                ...preparedSpread,
                index,
            }, transaction)
            if (!displayed) {
                this.#releaseSectionLeases(sectionLeases)
                return false
            }
        } catch (error) {
            this.#releaseSectionLeases(sectionLeases)
            return this.#navigationResultForError(error)
        }

        // Commit and release transaction ownership before document-scoped
        // observers run. Re-entrant navigation then starts a newer transaction
        // without retroactively cancelling this completed relocation.
        const committedContainer = this.#activeContainer
        const committedSectionIndex = this.index
        const committedFrames = [this.#center, this.#left, this.#right]
        this.#commitSectionLeases(sectionLeases)
        this.#finishNavigation(transaction)
        for (const frame of committedFrames) {
            if (this.#activeContainer !== committedContainer) break
            this.#publishFrameLoadAndCommit(frame, committedContainer)
        }
        if (
            this.#activeContainer === committedContainer
            && this.index === committedSectionIndex
        ) {
            this.#reportLocation(reason, transaction.relocationID)
        }
        return true
    }
    async goToSpread(index, side, reason, options = {}) {
        return await this.#runNavigation(transaction =>
            this.#goToSpread(index, side, reason, transaction),
            options
        )
    }
    async select(target, options = {}) {
        return await this.goTo(target, options)
    }
    async goTo(target, options = {}) {
        return await this.#runNavigation(async transaction => {
            const { book } = this
            let resolved
            try {
                const targetOperation = Promise.resolve(target).then(
                    value => ({ type: 'resolved', value }),
                    error => ({ type: 'failed', error })
                )
                let cancelListener
                const cancellation = new Promise(resolve => {
                    cancelListener = reason => resolve({ type: 'cancelled', reason })
                    transaction.cancellationListeners.add(cancelListener)
                    if (transaction.cancelled) cancelListener(transaction.reason)
                })
                const outcome = await Promise.race([targetOperation, cancellation])
                transaction.cancellationListeners.delete(cancelListener)
                if (outcome.type === 'cancelled') {
                    return fixedLayoutNonOwningResult(outcome.reason)
                }
                if (outcome.type === 'failed') throw outcome.error
                this.#requireCurrentNavigation(transaction)
                resolved = outcome.value
            } catch (error) {
                return this.#navigationResultForError(error)
            }
            if (!Number.isInteger(resolved?.index)) return false
            const section = book.sections[resolved.index]
            if (!section) return false
            const spreadTarget = this.getSpreadOf(section)
            if (!spreadTarget) return false
            return await this.#goToSpread(
                spreadTarget.index,
                spreadTarget.side,
                undefined,
                transaction
            )
        }, options)
    }
    async next(_distance, options = {}) {
        return await this.#runNavigation(async transaction => {
            if (!this.#isCurrentNavigation(transaction)) {
                return fixedLayoutNonOwningResult(transaction.reason)
            }
            const s = this.rtl ? this.#goLeft() : this.#goRight()
            if (s) {
                this.#finishNavigation(transaction)
                this.#reportLocation('page', transaction.relocationID)
                return true
            }
            const targetIndex = this.#adjacentLinearSpreadIndex(1)
            const targetSide = this.#resolvedNavigationSideForSpread(
                this.#spreads[targetIndex],
                this.rtl ? 'right' : 'left'
            )
            if (!targetSide) return false
            return await this.#goToSpread(targetIndex, targetSide, 'page', transaction)
        }, options)
    }
    async prev(_distance, options = {}) {
        return await this.#runNavigation(async transaction => {
            if (!this.#isCurrentNavigation(transaction)) {
                return fixedLayoutNonOwningResult(transaction.reason)
            }
            const s = this.rtl ? this.#goRight() : this.#goLeft()
            if (s) {
                this.#finishNavigation(transaction)
                this.#reportLocation('page', transaction.relocationID)
                return true
            }
            const targetIndex = this.#adjacentLinearSpreadIndex(-1)
            const targetSide = this.#resolvedNavigationSideForSpread(
                this.#spreads[targetIndex],
                this.rtl ? 'left' : 'right'
            )
            if (!targetSide) return false
            return await this.#goToSpread(targetIndex, targetSide, 'page', transaction)
        }, options)
    }
    getContents() {
        const frames = this.#center
            ? [this.#center]
            : [this.#left, this.#right].filter(Boolean)
        return frames.map(frame => ({
            doc: frame.iframe.contentDocument,
            iframe: frame.iframe,
            element: frame.element,
            index: Number(frame.iframe.dataset.index),
        }))
    }
    destroy() {
        if (this.#destroyed) return
        this.#destroyed = true
        this.#cancelNavigation(this.#navigationTransaction, 'fixedLayoutDestroyed')
        this.#navigationTransaction = null
        this.#resizeObserver.unobserve(this)
        this.#releaseSectionLeases(this.#activeSectionLeases)
        this.#activeSectionLeases = []
        this.#unloadFrameDocuments(
            [this.#center, this.#left, this.#right].filter(Boolean),
            'fixed-layout.destroy'
        )
        this.#activeContainer?.remove()
        this.#activeContainer = null
        this.#left = null
        this.#right = null
        this.#center = null
        this.#side = null
        this.#index = -1
    }
}

customElements.define('foliate-fxl', FixedLayout)
