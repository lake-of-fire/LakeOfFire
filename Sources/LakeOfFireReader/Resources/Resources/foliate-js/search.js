// length for context in excerpts
const CONTEXT_LENGTH = 50

const normalizeWhitespace = str => str.replace(/\s+/g, ' ')

const makeExcerpt = (strs, { startIndex, startOffset, endIndex, endOffset }) => {
    const start = strs[startIndex]
    const end = strs[endIndex]
    const match = startIndex === endIndex
        ? start.slice(startOffset, endOffset)
        : start.slice(startOffset)
            + strs.slice(startIndex + 1, endIndex).join('')
            + end.slice(0, endOffset)
    const trimmedStart = normalizeWhitespace(start.slice(0, startOffset)).trimStart()
    const trimmedEnd = normalizeWhitespace(end.slice(endOffset)).trimEnd()
    const ellipsisPre = trimmedStart.length < CONTEXT_LENGTH ? '' : '…'
    const ellipsisPost = trimmedEnd.length < CONTEXT_LENGTH ? '' : '…'
    const pre = `${ellipsisPre}${trimmedStart.slice(-CONTEXT_LENGTH)}`
    const post = `${trimmedEnd.slice(0, CONTEXT_LENGTH)}${ellipsisPost}`
    return { pre, match, post }
}

const simpleSearch = function* (strs, query, options = {}) {
    if (!query.length) return
    const { locales = 'en', sensitivity } = options
    const matchCase = sensitivity === 'variant'
    const haystack = strs.join('')
    const lowerHaystack = matchCase ? haystack : haystack.toLocaleLowerCase(locales)
    const needle = matchCase ? query : query.toLocaleLowerCase(locales)
    const needleLength = needle.length
    let index = -1
    let strIndex = 0
    let sum = 0
    do {
        index = lowerHaystack.indexOf(needle, index + 1)
        if (index > -1) {
            while (sum + strs[strIndex].length <= index) {
                sum += strs[strIndex++].length
            }
            const startIndex = strIndex
            const startOffset = index - sum
            const end = index + needleLength
            // End offsets are exclusive. Keep their cursor separate so a hit
            // at a node boundary stays in that node and overlapping matches
            // can still start before this match's final node.
            let endIndex = startIndex
            let endSum = sum
            while (endSum + strs[endIndex].length < end) {
                endSum += strs[endIndex++].length
            }
            const endOffset = end - endSum
            const range = { startIndex, startOffset, endIndex, endOffset }
            yield { range, excerpt: makeExcerpt(strs, range) }
        }
    } while (index > -1)
}

// Every comparison unit keeps the complete original grapheme span. This
// preserves UTF-16 offsets through omitted format tokens, whitespace runs and
// length-changing Unicode folds.
const mapSearchText = (text, segmenter, transform, collapseWhitespace = false) => {
    const values = [], starts = [], ends = []
    let previousValue
    for (const { index, segment } of segmenter.segment(text)) {
        const value = transform(segment)
        if (!value) continue
        const end = index + segment.length
        if (collapseWhitespace && value === ' ' && previousValue === ' ') {
            ends[ends.length - 1] = end
            continue
        }
        values.push(value)
        for (let i = 0; i < value.length; i++) {
            starts.push(index)
            ends.push(end)
        }
        previousValue = value
    }
    return { text: values.join(''), starts, ends }
}

const normalizeSearchSegment = segment => !/[^\p{Format}]/u.test(segment)
    ? '' : /^\s+$/u.test(segment) ? ' ' : segment

const segmentedCandidates = function* (text, query, segments, queryLength, collator) {
    for (let i = 0; i + queryLength <= segments.length; i++) {
        const start = segments[i].index
        const last = segments[i + queryLength - 1]
        const end = last.index + last.segment.length
        if (collator.compare(query, text.slice(start, end)) === 0) yield { start, end }
    }
}

const foldedCandidates = function* (text, query, graphemes, collator, boundaries) {
    const locale = collator.resolvedOptions().locale
    const ignoresMarks = ['base', 'case'].includes(collator.resolvedOptions().sensitivity)
    // A chapter repeats most graphemes. Keep locale casing/decomposition
    // bounded by distinct graphemes, with no cache surviving this search.
    const foldedSegments = new Map()
    const fold = segment => {
        if (foldedSegments.has(segment)) return foldedSegments.get(segment)
        const value = segment.normalize('NFKD').toLocaleLowerCase(locale)
            .toLocaleUpperCase(locale).normalize('NFKD')
        const folded = ignoresMarks ? value.replace(/\p{Mark}/gu, '') : value
        foldedSegments.set(segment, folded)
        return folded
    }
    const needle = mapSearchText(query, graphemes, fold).text
    if (!needle) return
    const key = mapSearchText(text, graphemes, fold)
    let index = -1
    while ((index = key.text.indexOf(needle, index + 1)) !== -1) {
        const start = key.starts[index], end = key.ends[index + needle.length - 1]
        if (boundaries && (!boundaries.has(start) || !boundaries.has(end))) continue
        // Unicode folds discover candidates, not collation keys. Verify the
        // complete original spelling, including sensitivity and locale; half
        // an expansion ("s" inside "ß") must never become a match.
        if (collator.compare(query, text.slice(start, end)) === 0) yield { start, end }
    }
}

const mergeCandidates = function* (first, second) {
    let a = first.next(), b = second.next(), previous
    while (!a.done || !b.done) {
        const useFirst = b.done || !a.done && (a.value.start < b.value.start
            || a.value.start === b.value.start && a.value.end <= b.value.end)
        const value = useFirst ? a.value : b.value
        if (useFirst) a = first.next()
        else b = second.next()
        if (value.start === previous?.start && value.end === previous?.end) continue
        previous = value
        yield value
    }
}

const collatedRanges = function* (text, query, options = {}) {
    if (!text.length || !query.length) return
    const { locales = 'en', granularity = 'grapheme', sensitivity = 'base' } = options
    let segmenter, graphemes, collator
    try {
        segmenter = new Intl.Segmenter(locales, { granularity })
        graphemes = new Intl.Segmenter(locales, { granularity: 'grapheme' })
        collator = new Intl.Collator(locales, { sensitivity })
    } catch (error) {
        console.warn(error)
        segmenter = new Intl.Segmenter('en', { granularity })
        graphemes = new Intl.Segmenter('en', { granularity: 'grapheme' })
        collator = new Intl.Collator('en', { sensitivity })
    }
    const normalized = mapSearchText(text, graphemes, normalizeSearchSegment, true)
    const needle = mapSearchText(query, graphemes, normalizeSearchSegment, true).text
    if (!normalized.text || !needle) return
    const segments = Array.from(segmenter.segment(normalized.text))
    const queryLength = Array.from(segmenter.segment(needle)).length
    const boundaries = granularity === 'grapheme' ? null
        : new Set([...segments.map(({ index }) => index), normalized.text.length])
    const candidates = mergeCandidates(
        segmentedCandidates(normalized.text, needle, segments, queryLength, collator),
        foldedCandidates(normalized.text, needle, graphemes, collator, boundaries))
    for (const { start, end } of candidates) {
        yield { startOffset: normalized.starts[start], endOffset: normalized.ends[end - 1] }
    }
}

// Collation keeps case-folding expansions out of DOM offsets. Segment the
// joined text so graphemes and words split across inline nodes stay intact,
// then map the original UTF-16 offsets back to those nodes.
const collatedSearch = function* (strs, query, options) {
    let startIndex = 0, startSum = 0
    for (const { startOffset: start, endOffset: end } of collatedRanges(strs.join(''), query, options)) {
        while (startSum + strs[startIndex].length <= start) {
            startSum += strs[startIndex++].length
        }
        let endIndex = startIndex, endSum = startSum
        while (endSum + strs[endIndex].length < end) {
            endSum += strs[endIndex++].length
        }
        const range = { startIndex, startOffset: start - startSum,
            endIndex, endOffset: end - endSum }
        yield { range, excerpt: makeExcerpt(strs, range) }
    }
}

export const search = (strs, query, options) => {
    const { granularity = 'grapheme', sensitivity = 'base' } = options
    if (!Intl?.Segmenter || granularity === 'grapheme'
    && sensitivity === 'variant')
        return simpleSearch(strs, query, options)
    return collatedSearch(strs, query, options)
}

export const searchMatcher = (textWalker, opts) => {
    const { defaultLocale, matchCase, matchDiacritics, matchWholeWords } = opts
    return function* (doc, query) {
        const iter = textWalker(doc, function* (strs, makeRange) {
            for (const result of search(strs, query, {
                locales: doc.body.lang || doc.documentElement.lang || defaultLocale || 'en',
                granularity: matchWholeWords ? 'word' : 'grapheme',
                sensitivity: matchDiacritics && matchCase ? 'variant'
                : matchDiacritics && !matchCase ? 'accent'
                : !matchDiacritics && matchCase ? 'case'
                : 'base',
            })) {
                const { startIndex, startOffset, endIndex, endOffset } = result.range
                result.range = makeRange(startIndex, startOffset, endIndex, endOffset)
                yield result
            }
        })
        for (const result of iter) yield result
    }
}
