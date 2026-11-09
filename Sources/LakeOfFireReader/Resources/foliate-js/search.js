// length for context in excerpts
const CONTEXT_LENGTH = 50

// Read only the normalized context that can appear in the excerpt. Scanning
// outward preserves the old trimStart/trimEnd behavior without normalizing
// the entire text-node prefix and suffix for every match.
const excerptContext = (text, offset, backwards) => {
    const step = backwards ? -1 : 1
    let index = backwards ? offset - 1 : offset
    const inside = () => index >= 0 && index < text.length
    const characters = []
    while (inside() && characters.length < CONTEXT_LENGTH) {
        const character = text[index]
        index += step
        if (/\s/.test(character)) {
            while (inside() && /\s/.test(text[index])) index += step
            // Whitespace at the outer edge was removed by trimStart/trimEnd.
            if (!inside()) break
            characters.push(' ')
        } else characters.push(character)
    }
    const ellipsis = characters.length < CONTEXT_LENGTH ? '' : '…'
    return backwards ? ellipsis + characters.reverse().join('')
        : characters.join('') + ellipsis
}

const makeExcerpt = (strs, { startIndex, startOffset, endIndex, endOffset }) => {
    const start = strs[startIndex]
    const end = strs[endIndex]
    const match = startIndex === endIndex
        ? start.slice(startOffset, endOffset)
        : start.slice(startOffset)
            + strs.slice(startIndex + 1, endIndex).join('')
            + end.slice(0, endOffset)
    const pre = excerptContext(start, startOffset, true)
    const post = excerptContext(end, endOffset, false)
    return { pre, match, post }
}

const simpleSearch = function* (strs, query, options = {}) {
    if (!query.length) return
    const { locales = 'en', sensitivity } = options
    const matchCase = sensitivity === 'variant' || sensitivity === 'case'
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
    // Locale digraphs must be expanded before marks are removed. Admit only
    // equivalences supported by this search's actual collation settings.
    const expansions = [['A\u030A', 'AA'], ['A\u0308', 'AE'], ['O\u0308', 'OE'], ['U\u0308', 'UE']]
        .filter(([source, target]) => collator.compare(source, target) === 0
            || collator.compare(source.toLocaleLowerCase(locale), target.toLocaleLowerCase(locale)) === 0)
    // A chapter repeats most graphemes. Keep locale casing/decomposition
    // bounded by distinct graphemes, with no cache surviving this search.
    const foldedSegments = new Map()
    const fold = segment => {
        if (foldedSegments.has(segment)) return foldedSegments.get(segment)
        let value = segment.normalize('NFKD').toLocaleLowerCase(locale)
            .toLocaleUpperCase(locale).normalize('NFKD')
        for (const [source, target] of expansions) value = value.replaceAll(source, target)
        // These collation expansions have no Unicode decomposition.
        // Original spans and the final collator still decide each match.
        value = value.replace(/Æ/g, 'AE').replace(/Œ/g, 'OE')
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

export const search = (strs, query, options) => {
    // Case and diacritic controls must not bypass whitespace/format-token
    // normalization or original grapheme spans. Variant collation still
    // distinguishes case and accents while accepting canonical equivalents.
    if (!Intl?.Segmenter) return simpleSearch(strs, query, options)
    return collatedSearch(strs, query, options)
}

export const searchMatcher = (textWalker, opts) => {
    // Keep the historical misspelling as a fallback for existing package callers.
    const { defaultLocale, defalutLocale, matchCase, matchDiacritics, matchWholeWords } = opts
    return function* (doc, query) {
        const iter = textWalker(doc, function* (strs, makeRange) {
            for (const result of search(strs, query, {
                locales: doc.body.lang || doc.documentElement.lang || defaultLocale || defalutLocale || 'en',
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
