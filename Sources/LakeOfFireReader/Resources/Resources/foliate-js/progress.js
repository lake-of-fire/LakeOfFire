// assign a unique ID for each TOC item
const assignIDs = toc => {
    let id = 0
    const assignID = item => {
        item.id = id++
        if (item.subitems) for (const subitem of item.subitems) assignID(subitem)
    }
    for (const item of toc) assignID(item)
    return toc
}

const flatten = items => items
    .map(item => item.subitems?.length
        ? [item, flatten(item.subitems)].flat()
        : item)
    .flat()

export class TOCProgress {
    constructor({ toc, ids, splitHref, getFragment }) {
        assignIDs(toc)
        const items = flatten(toc)
        const grouped = new Map()
        for (const [i, item] of items.entries()) {
            const [id, fragment] = splitHref(item?.href) ?? []
            const value = { fragment, item }
            if (grouped.has(id)) grouped.get(id).items.push(value)
            else grouped.set(id, { prev: items[i - 1], items: [value] })
        }
        const map = new Map()
        for (const [i, id] of ids.entries()) {
            if (grouped.has(id)) map.set(id, grouped.get(id))
            else map.set(id, map.get(ids[i - 1]))
        }
        this.ids = ids
        this.map = map
        this.getFragment = getFragment
    }
    getProgress(index, range) {
        const id = this.ids[index]
        const obj = this.map.get(id)
        if (!obj) return null
        const { prev, items } = obj
        if (!items) return prev
        if (!range || items.length === 1 && !items[0].fragment) return items[0].item

        const doc = range.startContainer.getRootNode()
        for (const [i, { fragment }] of items.entries()) {
            const el = this.getFragment(doc, fragment)
            if (!el) continue
            if (range.comparePoint(el, 0) > 0)
                return (items[i - 1]?.item ?? prev)
        }
        return items[items.length - 1].item
    }
}

export class SectionProgress {
    constructor(sections, sizePerLoc, sizePerTimeUnit) {
        this.sizes = sections.map(section => {
            const size = Number(section?.size)
            return section?.linear !== 'no' && Number.isFinite(size) && size > 0 ? size : 0
        })
        this.sizePerLoc = sizePerLoc
        this.sizePerTimeUnit = sizePerTimeUnit
        this.sizeTotal = this.sizes.reduce((a, b) => a + b, 0)
        this.sectionStarts = []
        this.linearSections = []
        let start = 0
        for (const [index, size] of this.sizes.entries()) {
            this.sectionStarts.push(start)
            if (size > 0) this.linearSections.push({ index, start, end: start + size, size })
            start += size
        }
    }
    // get progress given index of and fractions within a section
    getProgress(index, fractionInSection, pageFraction = 0) {
        const { sizes, sizePerLoc, sizePerTimeUnit, sizeTotal } = this
        const sizeInSection = sizes[index] ?? 0
        const sizeBefore = this.sectionStarts[index] ?? 0
        const size = sizeBefore + fractionInSection * sizeInSection
        const nextSize = size + pageFraction * sizeInSection
        const remainingTotal = sizeTotal - size
        const remainingSection = (1 - fractionInSection) * sizeInSection
        return {
            fraction: sizeTotal > 0 ? nextSize / sizeTotal : 0,
            section: {
                current: index,
                total: sizes.length,
            },
            location: {
                current: Math.floor(size / sizePerLoc),
                next: Math.floor(nextSize / sizePerLoc),
                total: Math.ceil(sizeTotal / sizePerLoc),
            },
            time: {
                section: remainingSection / sizePerTimeUnit,
                total: remainingTotal / sizePerTimeUnit,
            },
        }
    }
    // the inverse of `getProgress`
    // get index of and fraction in section based on total fraction
    getSection(fraction) {
        const { linearSections, sizeTotal } = this
        if (linearSections.length === 0 || sizeTotal <= 0) return [0, 0]

        const normalizedFraction = Number.isFinite(fraction)
            ? Math.max(0, Math.min(1, fraction))
            : (fraction === Number.POSITIVE_INFINITY ? 1 : 0)
        if (normalizedFraction <= 0) return [linearSections[0].index, 0]
        if (normalizedFraction >= 1) {
            return [linearSections[linearSections.length - 1].index, 1]
        }

        const target = normalizedFraction * sizeTotal
        const boundaryEpsilon = Number.EPSILON * Math.max(1, sizeTotal) * 4
        let lowerBound = 0
        let upperBound = linearSections.length
        while (lowerBound < upperBound) {
            const middle = lowerBound + Math.floor((upperBound - lowerBound) / 2)
            if (linearSections[middle].end > target + boundaryEpsilon) upperBound = middle
            else lowerBound = middle + 1
        }

        const section = linearSections[Math.min(lowerBound, linearSections.length - 1)]
        const fractionInSection = Math.max(0, Math.min(1, (target - section.start) / section.size))
        return [section.index, fractionInSection]
    }
}
