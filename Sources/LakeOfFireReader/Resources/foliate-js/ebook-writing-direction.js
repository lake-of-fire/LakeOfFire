const WRITING_MODE_PROPERTIES = new Set([
    'writing-mode',
    '-webkit-writing-mode',
    '-epub-writing-mode',
])

const normalizeWritingMode = value => {
    const normalized = String(value ?? '').trim().toLowerCase()
    if (normalized === 'vertical-rl' || normalized === 'tb-rl') return 'vertical-rl'
    if (normalized === 'vertical-lr' || normalized === 'tb-lr') return 'vertical-lr'
    if (normalized === 'horizontal-tb' || normalized === 'lr-tb' || normalized === 'rl-tb') {
        return 'horizontal-tb'
    }
    return null
}

const parseAttributes = source => {
    const attributes = new Map()
    const pattern = /([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g
    for (const match of String(source ?? '').matchAll(pattern)) {
        attributes.set(match[1].toLowerCase(), match[2] ?? match[3] ?? match[4] ?? '')
    }
    return attributes
}

const elementDescriptor = (html, tagName) => {
    const match = String(html ?? '').match(new RegExp(`<${tagName}\\b([^>]*)>`, 'i'))
    const attributes = parseAttributes(match?.[1])
    return {
        tagName,
        attributes,
        classes: new Set((attributes.get('class') ?? '').split(/\s+/).filter(Boolean)),
    }
}

const selectorSpecificity = selector => {
    const ids = selector.match(/#[\w-]+/g)?.length ?? 0
    const classes = selector.match(/\.[\w-]+|\[[^\]]+\]|:(?!root\b)[\w-]+/g)?.length ?? 0
    const elements = selector.match(/(^|[\s>+~,(])(html|body)(?=$|[\s>+~.#[:])/gi)?.length ?? 0
    return ids * 100 + classes * 10 + elements
}

const matchesSimpleSelector = (selector, element) => {
    let value = selector.trim()
    if (!value || value === '*') return true
    if (value.includes(':not(') || value.includes(':is(') || value.includes(':where(')) return false
    if (value === ':root') return element.tagName === 'html'
    value = value.replace(/:root/g, element.tagName === 'html' ? 'html' : '__not_root__')
    value = value.replace(/::?[\w-]+(?:\([^)]*\))?/g, '')

    const tag = value.match(/^[a-z][\w-]*/i)?.[0]?.toLowerCase()
    if (tag && tag !== element.tagName) return false
    for (const id of value.matchAll(/#([\w-]+)/g)) {
        if (element.attributes.get('id') !== id[1]) return false
    }
    for (const className of value.matchAll(/\.([\w-]+)/g)) {
        if (!element.classes.has(className[1])) return false
    }
    for (const attribute of value.matchAll(/\[\s*([\w:-]+)(?:\s*([~|^$*]?=)\s*["']?([^\]"']+)["']?)?\s*\]/g)) {
        const actual = element.attributes.get(attribute[1].toLowerCase())
        if (actual == null) return false
        const expected = attribute[3]?.trim()
        if (!attribute[2]) continue
        if (attribute[2] === '=' && actual !== expected) return false
        if (attribute[2] === '~=' && !actual.split(/\s+/).includes(expected)) return false
        if (attribute[2] === '^=' && !actual.startsWith(expected)) return false
        if (attribute[2] === '$=' && !actual.endsWith(expected)) return false
        if (attribute[2] === '*=' && !actual.includes(expected)) return false
        if (attribute[2] === '|=' && actual !== expected && !actual.startsWith(`${expected}-`)) return false
    }
    return true
}

const matchesSelector = (selector, element, root) => {
    const normalized = selector.trim()
    if (!normalized || /[>+~]/.test(normalized)) return false
    const parts = normalized.split(/\s+/)
    if (!matchesSimpleSelector(parts.at(-1), element)) return false
    if (parts.length === 1) return true
    return element.tagName === 'body'
        && parts.slice(0, -1).every(part => matchesSimpleSelector(part, root))
}

const declarationsFrom = source => {
    const declarations = []
    for (const declaration of String(source ?? '').split(';')) {
        const separator = declaration.indexOf(':')
        if (separator < 0) continue
        const property = declaration.slice(0, separator).trim().toLowerCase()
        if (!WRITING_MODE_PROPERTIES.has(property)) continue
        const rawValue = declaration.slice(separator + 1).trim()
        const important = /!important\s*$/i.test(rawValue)
        const writingMode = normalizeWritingMode(rawValue.replace(/!important\s*$/i, ''))
        if (writingMode) declarations.push({ writingMode, important })
    }
    return declarations
}

const cssRules = function* (source) {
    const css = String(source ?? '')
        .replace(/\/\*[\s\S]*?\*\//g, '')
        .replace(/@charset\s+[^;]+;/gi, '')
    let cursor = 0
    while (cursor < css.length) {
        const open = css.indexOf('{', cursor)
        if (open < 0) return
        let depth = 1
        let close = open + 1
        while (close < css.length && depth > 0) {
            if (css[close] === '{') depth += 1
            if (css[close] === '}') depth -= 1
            close += 1
        }
        if (depth !== 0) return
        const prelude = css.slice(cursor, open).trim()
        const body = css.slice(open + 1, close - 1)
        cursor = close
        if (!prelude) continue
        if (prelude.startsWith('@')) {
            const conditional = prelude.match(/^@(media|supports|layer)\s*(.*)$/i)
            if (!conditional) continue
            if (conditional[1].toLowerCase() === 'media'
                && !/(^|[\s,(])(all|screen)([\s,)]|$)/i.test(conditional[2])) continue
            yield* cssRules(body)
            continue
        }
        yield { selectors: prelude.split(','), body }
    }
}

const winningWritingMode = (element, root, stylesheets) => {
    let winner = null
    let order = 0
    const consider = (candidate, specificity) => {
        order += 1
        const rank = [candidate.important ? 1 : 0, specificity, order]
        if (!winner
            || rank[0] > winner.rank[0]
            || (rank[0] === winner.rank[0] && rank[1] > winner.rank[1])
            || (rank[0] === winner.rank[0] && rank[1] === winner.rank[1] && rank[2] > winner.rank[2])) {
            winner = { writingMode: candidate.writingMode, rank }
        }
    }

    for (const stylesheet of stylesheets) {
        for (const rule of cssRules(stylesheet)) {
            const selector = rule.selectors
                .filter(value => matchesSelector(value, element, root))
                .sort((left, right) => selectorSpecificity(right) - selectorSpecificity(left))[0]
            if (!selector) continue
            for (const declaration of declarationsFrom(rule.body)) {
                consider(declaration, selectorSpecificity(selector))
            }
        }
    }
    for (const declaration of declarationsFrom(element.attributes.get('style'))) {
        consider(declaration, 1_000)
    }
    return winner?.writingMode ?? null
}

export const resolveEbookRelativePath = (reference, relativeTo) => {
    if (typeof reference !== 'string' || reference.length === 0) return null
    if (/^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(reference)) return null
    try {
        const root = 'https://ebook.invalid/'
        const resolved = new URL(reference, `${root}${relativeTo ?? ''}`)
        if (!resolved.href.startsWith(root)) return null
        resolved.search = ''
        resolved.hash = ''
        return decodeURI(resolved.href.slice(root.length))
    } catch (_error) {
        return null
    }
}

const orderedStylesheets = async (href, html, loadText) => {
    const stylesheets = []
    const styleOrLink = /<style\b([^>]*)>([\s\S]*?)<\/style\s*>|<link\b([^>]*)>/gi
    const mediaApplies = attributes => {
        const media = (attributes.get('media') ?? '').trim()
        return !media || /(^|[\s,(])(all|screen)([\s,)]|$)/i.test(media)
    }
    for (const match of String(html ?? '').matchAll(styleOrLink)) {
        if (match[2] != null) {
            const attributes = parseAttributes(match[1])
            if (mediaApplies(attributes)) stylesheets.push(match[2])
            continue
        }
        const attributes = parseAttributes(match[3])
        const relationships = (attributes.get('rel') ?? '').toLowerCase().split(/\s+/)
        if (!relationships.includes('stylesheet') || relationships.includes('alternate')) continue
        if (!mediaApplies(attributes)) continue
        const stylesheetHref = resolveEbookRelativePath(attributes.get('href'), href)
        if (!stylesheetHref || typeof loadText !== 'function') continue
        try {
            const stylesheet = await loadText(stylesheetHref)
            if (typeof stylesheet === 'string') stylesheets.push(stylesheet)
        } catch (_error) {
            // A missing optional stylesheet leaves source direction unresolved.
        }
    }
    return stylesheets
}

export const rawSectionWritingDirection = async ({ href, html, loadText = null }) => {
    if (typeof html !== 'string' || html.length === 0) return null
    const root = elementDescriptor(html, 'html')
    const body = elementDescriptor(html, 'body')
    const stylesheets = await orderedStylesheets(href, html, loadText)
    const writingMode = winningWritingMode(body, root, stylesheets)
        ?? winningWritingMode(root, root, stylesheets)
    if (writingMode?.startsWith('vertical-')) return { direction: 'vertical', writingMode }
    if (writingMode === 'horizontal-tb') return { direction: 'horizontal', writingMode }

    const classes = new Set([...root.classes, ...body.classes])
    if (['vrtl', 'vertical', 'reader-vertical-writing'].some(value => classes.has(value))) {
        return { direction: 'vertical', writingMode: 'vertical-rl' }
    }
    if (classes.has('hltr')) return { direction: 'horizontal', writingMode: 'horizontal-tb' }
    return null
}

export const makeRawSectionWritingDirectionResolver = ({ loadText }) => {
    const cache = new Map()
    return async href => {
        if (typeof href !== 'string' || href.length === 0 || typeof loadText !== 'function') return null
        if (!cache.has(href)) {
            cache.set(href, Promise.resolve(loadText(href)).then(html =>
                rawSectionWritingDirection({ href, html, loadText })))
        }
        return cache.get(href)
    }
}
