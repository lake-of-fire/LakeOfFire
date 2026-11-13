import { getDocumentLanguage } from './content-language.js'

// length for context in excerpts
const CONTEXT_LENGTH = 50

// Read only the normalized context that can appear in the excerpt. Scanning
// outward preserves the old trimStart/trimEnd behavior without normalizing
// the entire text-node prefix and suffix for every match.
const excerptContext = (text, offset, backwards, skipWhitespace) => {
    const step = backwards ? -1 : 1
    let index = backwards ? offset - 1 : offset
    const inside = () => index >= 0 && index < text.length
    const characters = []
    while (inside() && characters.length < CONTEXT_LENGTH) {
        const character = text[index]
        index += step
        if (/\s/.test(character)) {
            if (skipWhitespace) index = skipWhitespace(index - step, backwards)
            else while (inside() && /\s/.test(text[index])) index += step
            // Whitespace at the outer edge was removed by trimStart/trimEnd.
            if (!inside()) break
            characters.push(' ')
        } else characters.push(character)
    }
    const ellipsis = characters.length < CONTEXT_LENGTH ? '' : '…'
    return backwards ? ellipsis + characters.reverse().join('')
        : characters.join('') + ellipsis
}

const makeExcerpt = (strs, { startIndex, startOffset, endIndex, endOffset }, whitespaceSkipper) => {
    const start = strs[startIndex]
    const end = strs[endIndex]
    const match = startIndex === endIndex
        ? start.slice(startOffset, endOffset)
        : start.slice(startOffset)
            + strs.slice(startIndex + 1, endIndex).join('')
            + end.slice(0, endOffset)
    const pre = excerptContext(start, startOffset, true, whitespaceSkipper?.(startIndex))
    const post = excerptContext(end, endOffset, false, whitespaceSkipper?.(endIndex))
    return { pre, match, post }
}

// Literal fallback hits can repeatedly enter the same long whitespace run.
// Cache only long runs actually encountered, within this generator's lifetime;
// do not scan or index the rest of a node for a sparse early match.
const makeWhitespaceSkipper = strs => {
    const nodes = new Map()
    return nodeIndex => (offset, backwards) => {
        const text = strs[nodeIndex]
        let entry = nodes.get(nodeIndex)
        if (!entry || entry.text !== text) {
            entry = { text, runs: [] }
            nodes.set(nodeIndex, entry)
        }
        const { runs } = entry
        let low = 0, high = runs.length
        while (low < high) {
            const middle = (low + high) >>> 1
            if (runs[middle][1] <= offset) low = middle + 1
            else high = middle
        }
        const cached = runs[low]
        if (cached && cached[0] <= offset)
            return backwards ? cached[0] - 1 : cached[1]
        const step = backwards ? -1 : 1
        let index = offset
        while (index >= 0 && index < text.length && /\s/.test(text[index])) index += step
        if (Math.abs(index - offset) > 64) {
            let opposite = offset - step
            while (opposite >= 0 && opposite < text.length && /\s/.test(text[opposite])) opposite -= step
            const start = backwards ? index + 1 : opposite + 1
            const end = backwards ? opposite : index
            runs.splice(low, 0, [start, end])
        }
        return index
    }
}

// Locale casing can change UTF-16 length (for example, English İ -> i + dot).
// Keep only the changed casing spans, rather than an offset entry per code unit.
// Base characters stay with their combining marks so contextual Turkish and
// Lithuanian casing can remove or add dots without shifting later DOM ranges.
const caseFoldOffsetMap = (text, foldedText, locales) => {
    if (text === foldedText || /^[\x00-\x7f]*$/.test(text)) return null
    const spans = []
    const lengths = new Map()
    let foldedStart = 0
    for (const { 0: segment, index: originalStart } of text.matchAll(/\P{Mark}\p{Mark}*|\p{Mark}+/gu)) {
        let length = lengths.get(segment)
        if (length === undefined) {
            length = segment.toLocaleLowerCase(locales).length
            lengths.set(segment, length)
        }
        const foldedEnd = foldedStart + length
        const originalEnd = originalStart + segment.length
        if (length !== segment.length) {
            spans.push({ foldedStart, foldedEnd, originalStart, originalEnd,
                deltaAfter: originalEnd - foldedEnd })
        }
        foldedStart = foldedEnd
    }
    if (!spans.length) return null
    return (offset, end) => {
        let low = 0, high = spans.length
        while (low < high) {
            const middle = (low + high) >>> 1
            if (spans[middle].foldedStart <= offset) low = middle + 1
            else high = middle
        }
        const span = spans[low - 1]
        if (span && offset < span.foldedEnd)
            return end ? span.originalEnd : span.originalStart
        return offset + (span?.deltaAfter ?? 0) + (end ? 1 : 0)
    }
}

const simpleSearch = function* (strs, query, options = {}) {
    if (!query.length) return
    const { locales = 'en', sensitivity } = options
    const matchCase = sensitivity === 'variant' || sensitivity === 'case'
    const haystack = strs.join('')
    const lowerHaystack = matchCase ? haystack : haystack.toLocaleLowerCase(locales)
    const originalOffset = matchCase ? null : caseFoldOffsetMap(haystack, lowerHaystack, locales)
    const needle = matchCase ? query : query.toLocaleLowerCase(locales)
    const needleLength = needle.length
    const whitespaceSkipper = makeWhitespaceSkipper(strs)
    let index = -1
    let strIndex = 0
    let sum = 0
    let previousStart, previousEnd
    do {
        index = lowerHaystack.indexOf(needle, index + 1)
        if (index > -1) {
            const start = originalOffset ? originalOffset(index, false) : index
            const end = originalOffset ? originalOffset(index + needleLength - 1, true) : index + needleLength
            if (start === previousStart && end === previousEnd) continue
            previousStart = start
            previousEnd = end
            while (sum + strs[strIndex].length <= start) {
                sum += strs[strIndex++].length
            }
            const startIndex = strIndex
            const startOffset = start - sum
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
            yield { range, excerpt: makeExcerpt(strs, range, whitespaceSkipper) }
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
    // Printable ASCII has single-code-unit graphemes and no format tokens.
    // With no whitespace run, normalization and its offset map are identities.
    const identityOffsets = /^[\x20-\x7e]*$/.test(text) && !text.includes('  ')
    const normalized = identityOffsets ? { text }
        : mapSearchText(text, graphemes, normalizeSearchSegment, true)
    const needle = mapSearchText(query, graphemes, normalizeSearchSegment, true).text
    if (!normalized.text || !needle) return
    const segments = Array.from(segmenter.segment(normalized.text))
    const queryLength = Array.from(segmenter.segment(needle)).length
    const boundaries = granularity === 'grapheme' ? null
        : new Set([...segments.map(({ index }) => index), normalized.text.length])
    let candidates = mergeCandidates(
        segmentedCandidates(normalized.text, needle, segments, queryLength, collator),
        foldedCandidates(normalized.text, needle, graphemes, collator, boundaries))
    if (granularity === 'grapheme') {
        // Substring mode must include every whole-word collation match, even
        // when a language expansion (such as œ/oe) has no Unicode fold key.
        const words = new Intl.Segmenter(segmenter.resolvedOptions().locale, {granularity:'word'})
        candidates = mergeCandidates(candidates, segmentedCandidates(normalized.text, needle,
            Array.from(words.segment(normalized.text)), Array.from(words.segment(needle)).length, collator))
    }
    for (const { start, end } of candidates) {
        yield { startOffset: identityOffsets ? start : normalized.starts[start],
            endOffset: identityOffsets ? end : normalized.ends[end - 1] }
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

export const search = (strs, query, options = {}) => {
    // Case and diacritic controls must not bypass whitespace/format-token
    // normalization or original grapheme spans. Variant collation still
    // distinguishes case and accents while accepting canonical equivalents.
    if (!Intl?.Segmenter) return simpleSearch(strs, query, options)
    return collatedSearch(strs, query, options)
}

export const searchMatcher = (textWalker, opts) => {
    // Preserve the historical spelling for existing package callers.
    const { defaultLocale, defalutLocale, matchCase, matchDiacritics, matchWholeWords } = opts
    return function* (doc, query) {
        const iter = textWalker(doc, function* (strs, makeRange) {
            for (const result of search(strs, query, {
                locales: (getDocumentLanguage(doc) ?? (defaultLocale || defalutLocale)) || 'en',
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

