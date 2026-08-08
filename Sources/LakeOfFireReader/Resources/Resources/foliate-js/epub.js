import * as CFI from './epubcfi.js'

const NS = {
    CONTAINER: 'urn:oasis:names:tc:opendocument:xmlns:container',
    XHTML: 'http://www.w3.org/1999/xhtml',
    OPF: 'http://www.idpf.org/2007/opf',
    EPUB: 'http://www.idpf.org/2007/ops',
    DC: 'http://purl.org/dc/elements/1.1/',
    DCTERMS: 'http://purl.org/dc/terms/',
    ENC: 'http://www.w3.org/2001/04/xmlenc#',
    NCX: 'http://www.daisy.org/z3986/2005/ncx/',
    XLINK: 'http://www.w3.org/1999/xlink',
    SMIL: 'http://www.w3.org/ns/SMIL',
    SVG: 'http://www.w3.org/2000/svg',
}

const MIME = {
    XML: 'application/xml',
    NCX: 'application/x-dtbncx+xml',
    XHTML: 'application/xhtml+xml',
    HTML: 'text/html',
    CSS: 'text/css',
    SVG: 'image/svg+xml',
    JS: /\/(x-)?(javascript|ecmascript)/,
}

// convert to camel case
const camel = x => x.toLowerCase().replace(/[-:](.)/g, (_, g) => g.toUpperCase())

// strip and collapse ASCII whitespace
// https://infra.spec.whatwg.org/#strip-and-collapse-ascii-whitespace
const normalizeWhitespace = str => str ? str
    .replace(/[\t\n\f\r ]+/g, ' ')
    .replace(/^[\t\n\f\r ]+/, '')
    .replace(/[\t\n\f\r ]+$/, '') : ''

const filterAttribute = (attr, value, isList) => isList ?
    el => el.getAttribute(attr)?.split(/\s/)?.includes(value) :
    typeof value === 'function' ?
    el => value(el.getAttribute(attr)) :
    el => el.getAttribute(attr) === value

const getAttributes = (...xs) => el =>
    el ? Object.fromEntries(xs.map(x => [camel(x), el.getAttribute(x)])) : null

const getElementText = el => normalizeWhitespace(el?.textContent)

const childGetter = (doc, ns) => {
    // ignore the namespace if it doesn't appear in document at all
    const useNS = doc.lookupNamespaceURI(null) === ns || doc.lookupPrefix(ns)
    const f = useNS ?
        (el, name) => el => el.namespaceURI === ns && el.localName === name :
        (el, name) => el => el.localName === name
    return {
        $: (el, name) => [...el.children].find(f(el, name)),
        $$: (el, name) => [...el.children].filter(f(el, name)),
        $$$: useNS ?
            (el, name) => [...el.getElementsByTagNameNS(ns, name)] : (el, name) => [...el.getElementsByTagName(name)],
    }
}

const URI_SCHEME = /^[A-Za-z][A-Za-z0-9+.-]*:/
const hasURIScheme = value => URI_SCHEME.test(String(value ?? ''))
const trimASCIIURLWhitespace = value => String(value ?? '')
    .replace(/^[\t\n\f\r ]+|[\t\n\f\r ]+$/g, '')

const resolvePackageEntryPath = value => {
    const normalized = trimASCIIURLWhitespace(value)
    if (!normalized
        || hasURIScheme(normalized)
        || normalized.startsWith('/')
        || normalized.startsWith('//')) return null

    const path = normalized.split('#', 1)[0].split('?', 1)[0]
    let decoded
    try {
        // `decodeURI` decodes ordinary filename escapes while preserving escaped
        // path delimiters such as `%2F`, matching package-entry identity.
        decoded = decodeURI(path)
    } catch (_error) {
        return null
    }
    if (!decoded || decoded.includes('\\') || decoded.includes('\0')) return null

    const resolved = []
    for (const component of decoded.split('/')) {
        if (!component) return null
        if (component === '.') continue
        if (component === '..') {
            if (!resolved.length) return null
            resolved.pop()
        } else resolved.push(component)
    }
    return resolved.join('/') || null
}

const resolveURL = (url, relativeTo) => {
    try {
        const base = trimASCIIURLWhitespace(relativeTo)
        const target = String(url ?? '')
        // Package paths are not URLs, so resolve them under a temporary origin
        // and remove that origin afterward. A colon inside a path segment is not
        // a URI scheme and must not switch this operation into absolute-URL mode.
        const root = 'https://invalid.invalid/'
        const absoluteBase = hasURIScheme(base)
        const networkBase = base.startsWith('//')
        // URL parsing ignores surrounding ASCII whitespace. Classify the target
        // after the same normalization so a formatted outbound href cannot be
        // mistaken for a package path and lose its query.
        const normalizedTarget = trimASCIIURLWhitespace(target)
        const externalTarget = hasURIScheme(normalizedTarget)
            || normalizedTarget.startsWith('//')
        const containerTarget = !absoluteBase && !networkBase && !externalTarget
        const obj = new URL(
            target,
            absoluteBase ? base : networkBase ? `https:${base}` : root + base,
        )
        // Queries are not part of an OCF container resource path, but they are
        // semantically significant for outbound links and remote resources.
        if (containerTarget) obj.search = ''
        // Preserve the browser's serialized encoding for outbound URLs. Running
        // `decodeURI` over a remote query can collapse deliberate double encoding
        // before the external-link consumer parses the URL again.
        return containerTarget ? decodeURI(obj.href.replace(root, '')) : obj.href
    } catch (e) {
        console.warn(e)
        return url
    }
}

const isExternal = uri => hasURIScheme(uri) && !/^blob:/i.test(String(uri))

// like `path.relative()` in Node.js
const pathRelative = (from, to) => {
    if (!from) return to
    const as = from.replace(/\/$/, '').split('/')
    const bs = to.replace(/\/$/, '').split('/')
    const i = (as.length > bs.length ? as : bs).findIndex((_, i) => as[i] !== bs[i])
    return i < 0 ? '' : Array(as.length - i).fill('..').concat(bs.slice(i)).join('/')
}

const pathDirname = str => str.slice(0, str.lastIndexOf('/') + 1)

// replace asynchronously and sequentially
// same techinque as https://stackoverflow.com/a/48032528
const replaceSeries = async (str, regex, f) => {
    const matches = []
    str.replace(regex, (...args) => (matches.push(args), null))
    const results = []
    for (const args of matches) results.push(await f(...args))
    return str.replace(regex, () => results.shift())
}

const regexEscape = str => str.replace(/[-/\\^$*+?.()|[\]{}]/g, '\\$&')

// `replaceString` is deliberately a lightweight fallback for JavaScript rather
// than a JavaScript parser. Restrict rewriting to complete standalone or quoted
// URL tokens so a local asset such as `image.png` cannot rewrite arbitrary text,
// longer filenames, nested paths, or the suffix of an external URL.
const RAW_RESOURCE_REFERENCE_QUOTES = new Set(['"', "'", '`'])
const rawResourceReferenceIsComplete = (source, offset, length) => {
    const before = offset > 0 ? source[offset - 1] : null
    const after = offset + length < source.length
        ? source[offset + length]
        : null
    return (before == null || RAW_RESOURCE_REFERENCE_QUOTES.has(before))
        && (after == null || RAW_RESOURCE_REFERENCE_QUOTES.has(after))
}

// Blob URL lookup excludes fragments, but not queries. Appending a publication
// query to an object URL therefore makes the generated URL unresolvable. Raw
// replacement consumes the query while retaining a fragment, matching loadHref.
const RAW_RESOURCE_SUFFIX = String.raw`(?:\?[^"'\x60\s#]*)?(#[^"'\x60\s]*)?`

const RESOURCE_LINK_RELATIONS = new Set([
    'apple-touch-icon',
    'icon',
    'manifest',
    'mask-icon',
    'modulepreload',
    'prefetch',
    'preload',
    'resource',
    'stylesheet',
])

// SVG paint servers and effects are CSS values even when serialized as
// presentation attributes. Once the document is blob-backed, package-relative
// URLs in these attributes need the same lexical URL rewriting as a style
// declaration. Restrict the pass to attributes whose value grammar can carry a
// resource URL; arbitrary SVG/XML metadata must remain untouched.
const SVG_CSS_RESOURCE_ATTRIBUTES = [
    'clip-path',
    'color-profile',
    'cursor',
    'fill',
    'filter',
    'marker',
    'marker-end',
    'marker-mid',
    'marker-start',
    'mask',
    'stroke',
]
const linkElementLoadsResource = element => String(
    element?.getAttribute?.('rel') ?? ''
).split(/[\t\n\f\r ]+/).some(token => (
    RESOURCE_LINK_RELATIONS.has(token.toLowerCase())
))

const isASCIIWhitespace = char => char === ' '
    || char === '\t'
    || char === '\n'
    || char === '\f'
    || char === '\r'

const isCSSNameCharacter = char => char != null
    && (char === '\\' || /[A-Za-z0-9_-]/.test(char) || char.codePointAt(0) >= 0x80)

const isCSSNewline = char => char === '\n' || char === '\r' || char === '\f'

const skipCSSEscape = (source, start) => {
    let position = start + 1
    if (position >= source.length) return position
    if (source[position] === '\r' && source[position + 1] === '\n') {
        return position + 2
    }
    if (/[0-9a-fA-F]/.test(source[position])) {
        let digits = 0
        while (digits < 6 && /[0-9a-fA-F]/.test(source[position])) {
            position += 1
            digits += 1
        }
        if (source[position] === '\r' && source[position + 1] === '\n') {
            return position + 2
        }
        return isASCIIWhitespace(source[position]) ? position + 1 : position
    }
    return position + 1
}

// Consume a CSS identifier while retaining the browser's escape semantics.
// Resource-bearing function and at-keyword names may legally contain escapes
// (`u\72l`, `image\2d set`, `@\69mport`); resolving only their literal
// spellings leaves valid package-relative URLs stranded inside blob stylesheets.
const parseCSSIdentifier = (source, start) => {
    let position = start
    while (position < source.length) {
        const char = source[position]
        if (char === '\\') {
            const escaped = source[position + 1]
            // A backslash followed by EOF or a newline is not a valid escape in
            // an identifier token, so it terminates this candidate.
            if (escaped == null || isCSSNewline(escaped)) break
            position = skipCSSEscape(source, position)
            continue
        }
        if (!isCSSNameCharacter(char)) break
        position += 1
    }
    if (position === start) return null
    return {
        end: position,
        value: decodeCSSURLValue(source.slice(start, position)),
    }
}

const skipCSSString = (source, start, quote) => {
    let position = start + 1
    while (position < source.length) {
        const char = source[position]
        if (char === '\\') {
            position = skipCSSEscape(source, position)
            continue
        }
        position += 1
        if (char === quote) break
    }
    return position
}

const skipCSSWhitespaceAndComments = (source, start) => {
    let position = start
    while (position < source.length) {
        while (isASCIIWhitespace(source[position])) position += 1
        if (source[position] !== '/' || source[position + 1] !== '*') break
        const commentEnd = source.indexOf('*/', position + 2)
        if (commentEnd < 0) return source.length
        position = commentEnd + 2
    }
    return position
}

const decodeCSSURLValue = value => String(value ?? '').replace(
    /\\(?:([0-9a-fA-F]{1,6})(?:\r\n|[\t\n\f\r ])?|\r\n|[\n\r\f]|(.))/g,
    (_match, hex, escaped) => {
        if (hex) {
            const codePoint = Number.parseInt(hex, 16)
            const invalid = codePoint === 0
                || codePoint > 0x10FFFF
                || (codePoint >= 0xD800 && codePoint <= 0xDFFF)
            return invalid ? '\uFFFD' : String.fromCodePoint(codePoint)
        }
        return escaped ?? ''
    },
)

const escapeCSSStringValue = (value, quote = '"') => String(value).replace(
    /(["'\\\n\r\f])/g,
    char => char === quote || char === '\\'
        ? `\\${char}`
        : `\\${char.codePointAt(0).toString(16)} `,
)

const parseCSSQuotedValue = (source, start) => {
    const quote = source[start]
    if (quote !== '"' && quote !== "'") return null
    let position = start + 1
    while (position < source.length) {
        const char = source[position]
        if (char === '\\') {
            position = skipCSSEscape(source, position)
            continue
        }
        if (char === quote) {
            return {
                end: position + 1,
                quote,
                value: decodeCSSURLValue(source.slice(start + 1, position)),
            }
        }
        position += 1
    }
    return null
}

const parseCSSURLFunction = (source, start) => {
    const first = source[start]
    if (first !== 'u' && first !== 'U' && first !== '\\') return null
    if (isCSSNameCharacter(source[start - 1])) return null
    const identifier = parseCSSIdentifier(source, start)
    if (identifier?.value.toLowerCase() !== 'url') return null
    if (source[identifier.end] !== '(') return null

    let position = skipCSSWhitespaceAndComments(source, identifier.end + 1)
    const quoted = parseCSSQuotedValue(source, position)
    if (quoted) {
        position = skipCSSWhitespaceAndComments(source, quoted.end)
        if (source[position] !== ')') return null
        return {
            replaceStart: start,
            replaceEnd: position + 1,
            value: quoted.value,
            render: replacement => `url("${escapeCSSStringValue(replacement)}")`,
        }
    }

    const valueStart = position
    let valueEnd = position
    while (position < source.length) {
        const char = source[position]
        if (char === '\\') {
            position = skipCSSEscape(source, position)
            valueEnd = position
            continue
        }
        if (char === ')') {
            return {
                replaceStart: start,
                replaceEnd: position + 1,
                value: decodeCSSURLValue(source.slice(valueStart, valueEnd)),
                render: replacement => `url("${escapeCSSStringValue(replacement)}")`,
            }
        }
        if (isASCIIWhitespace(char) || (char === '/' && source[position + 1] === '*')) {
            valueEnd = position
            position = skipCSSWhitespaceAndComments(source, position)
            if (source[position] !== ')') return null
            return {
                replaceStart: start,
                replaceEnd: position + 1,
                value: decodeCSSURLValue(source.slice(valueStart, valueEnd)),
                render: replacement => `url("${escapeCSSStringValue(replacement)}")`,
            }
        }
        position += 1
        valueEnd = position
    }
    return null
}

const parseCSSQuotedImport = (source, start) => {
    if (source[start] !== '@') return null
    const identifier = parseCSSIdentifier(source, start + 1)
    if (identifier?.value.toLowerCase() !== 'import') return null
    const valueStart = skipCSSWhitespaceAndComments(source, identifier.end)
    const quoted = parseCSSQuotedValue(source, valueStart)
    if (!quoted) return null
    return {
        replaceStart: valueStart,
        replaceEnd: quoted.end,
        value: quoted.value,
        render: replacement => `${quoted.quote}${escapeCSSStringValue(replacement, quoted.quote)}${quoted.quote}`,
    }
}

const CSS_IMAGE_SET_FUNCTIONS = new Set(['-webkit-image-set', 'image-set'])
const parseCSSImageSetStart = (source, start) => {
    const first = source[start]
    if (first !== '-' && first !== 'i' && first !== 'I' && first !== '\\') return null
    if (isCSSNameCharacter(source[start - 1])) return null
    const identifier = parseCSSIdentifier(source, start)
    if (!CSS_IMAGE_SET_FUNCTIONS.has(identifier?.value.toLowerCase())) return null
    if (source[identifier.end] !== '(') return null
    return { end: identifier.end + 1 }
}

const rewriteCSS = async (source, replaceURL, transformCode) => {
    const text = String(source ?? '')
    const parts = []
    const functionStack = []
    let cursor = 0
    let position = 0
    const directImageSet = () => {
        const frame = functionStack.at(-1)
        return frame?.imageSet ? frame : null
    }
    const appendProtected = (start, end, replacement = text.slice(start, end)) => {
        parts.push(transformCode(text.slice(cursor, start)))
        parts.push(replacement)
        cursor = end
        position = end
    }
    const replaceParsed = async parsed => {
        const original = text.slice(parsed.replaceStart, parsed.replaceEnd)
        const replacement = parsed.value
            ? await replaceURL(parsed.value)
            : parsed.value
        appendProtected(
            parsed.replaceStart,
            parsed.replaceEnd,
            replacement === parsed.value ? original : parsed.render(replacement),
        )
    }
    while (position < text.length) {
        const char = text[position]
        if (char === '/' && text[position + 1] === '*') {
            const commentEnd = text.indexOf('*/', position + 2)
            appendProtected(position, commentEnd < 0 ? text.length : commentEnd + 2)
            continue
        }
        if (char === '"' || char === "'") {
            const imageSet = functionStack.length ? directImageSet() : null
            if (imageSet?.awaitingSource) {
                const parsed = parseCSSQuotedValue(text, position)
                if (parsed) {
                    imageSet.awaitingSource = false
                    await replaceParsed({
                        replaceStart: position,
                        replaceEnd: parsed.end,
                        value: parsed.value,
                        render: replacement => (
                            `${parsed.quote}${escapeCSSStringValue(replacement, parsed.quote)}${parsed.quote}`
                        ),
                    })
                    continue
                }
            }
            appendProtected(position, skipCSSString(text, position, char))
            continue
        }
        const parsed = parseCSSURLFunction(text, position)
            ?? parseCSSQuotedImport(text, position)
        if (parsed) {
            const imageSet = functionStack.length ? directImageSet() : null
            if (imageSet?.awaitingSource && parsed.replaceStart === position) {
                imageSet.awaitingSource = false
            }
            await replaceParsed(parsed)
            continue
        }
        const imageSetStart = parseCSSImageSetStart(text, position)
        if (imageSetStart) {
            const parentImageSet = functionStack.length ? directImageSet() : null
            if (parentImageSet?.awaitingSource) parentImageSet.awaitingSource = false
            functionStack.push({ imageSet: true, awaitingSource: true })
            position = imageSetStart.end
            continue
        }
        if (char === '(') {
            if (functionStack.length) {
                const imageSet = directImageSet()
                if (imageSet?.awaitingSource) imageSet.awaitingSource = false
                functionStack.push({ imageSet: false })
            }
            position += 1
            continue
        }
        if (char === ')') {
            if (functionStack.length) functionStack.pop()
            position += 1
            continue
        }
        if (char === ',' && functionStack.length) {
            const imageSet = directImageSet()
            if (imageSet) {
                imageSet.awaitingSource = true
                position += 1
                continue
            }
        }
        if (!isASCIIWhitespace(char) && functionStack.length) {
            const imageSet = directImageSet()
            if (imageSet?.awaitingSource) imageSet.awaitingSource = false
        }
        position += 1
    }
    parts.push(transformCode(text.slice(cursor)))
    return parts.join('')
}

// Parse enough of the HTML `srcset` algorithm to preserve data URLs and commas
// inside descriptor functions while exposing each candidate URL for replacement.
// Candidate validation remains the browser's responsibility.
const parseSrcsetCandidates = value => {
    const source = String(value ?? '')
    const candidates = []
    let position = 0
    while (position < source.length) {
        while (
            position < source.length
            && (isASCIIWhitespace(source[position]) || source[position] === ',')
        ) position += 1
        if (position >= source.length) break

        const urlStart = position
        while (position < source.length && !isASCIIWhitespace(source[position])) {
            position += 1
        }
        let url = source.slice(urlStart, position)
        if (!url) continue

        if (url.endsWith(',')) {
            url = url.replace(/,+$/, '')
            if (url) candidates.push({ url, descriptor: '' })
            continue
        }

        const descriptorStart = position
        let parentheses = 0
        while (position < source.length) {
            const char = source[position]
            if (char === '(') parentheses += 1
            else if (char === ')' && parentheses > 0) parentheses -= 1
            else if (char === ',' && parentheses === 0) break
            position += 1
        }
        const descriptor = source.slice(descriptorStart, position).trim()
        if (position < source.length && source[position] === ',') position += 1
        candidates.push({ url, descriptor })
    }
    return candidates
}

const LANGS = {
    attrs: ['dir', 'xml:lang']
}
const ALTS = {
    name: 'alternate-script',
    many: true,
    ...LANGS,
    props: ['file-as']
}
const CONTRIB = {
    many: true,
    ...LANGS,
    props: [{
        name: 'role',
        many: true,
        attrs: ['scheme']
    }, 'file-as', ALTS],
}
const METADATA = [{
        name: 'title',
        many: true,
        ...LANGS,
        props: ['title-type', 'display-seq', 'file-as', ALTS],
    },
    {
        name: 'identifier',
        many: true,
        props: [{
            name: 'identifier-type',
            attrs: ['scheme']
        }],
    },
    {
        name: 'language',
        many: true
    },
    {
        name: 'creator',
        ...CONTRIB
    },
    {
        name: 'contributor',
        ...CONTRIB
    },
    {
        name: 'publisher',
        ...LANGS,
        props: ['file-as', ALTS]
    },
    {
        name: 'description',
        ...LANGS,
        props: [ALTS]
    },
    {
        name: 'rights',
        ...LANGS,
        props: [ALTS]
    },
    {
        name: 'date'
    },
    {
        name: 'dcterms:modified',
        type: 'meta'
    },
    {
        name: 'subject',
        many: true,
        ...LANGS,
        props: ['term', 'authority', ALTS]
    },
    {
        name: 'belongs-to-collection',
        type: 'meta',
        many: true,
        ...LANGS,
        props: [
            'collection-type', 'group-position', 'dcterms:identifier', 'file-as',
            ALTS, {
                name: 'belongs-to-collection',
                recursive: true
            },
        ],
    },
]

// NOTE: this only gets properties defined with the `refines` attribute,
// which is used in EPUB 3.0, deprecated in 3.1, then restored in 3.2;
// no support for `opf:` attributes of 2.0 and 3.1
const getMetadata = opf => {
    const {
        $,
        $$
    } = childGetter(opf, NS.OPF)
    const $metadata = $(opf.documentElement, 'metadata')
    const els = Array.from($metadata.children)
    const getValue = (obj, el) => {
        if (!el) return null
        const {
            props = [], attrs = []
        } = obj
        const value = getElementText(el)
        if (!props.length && !attrs.length) return value
        const id = el.getAttribute('id')
        const refines = id ? els.filter(filterAttribute('refines', '#' + id)) : []
        return Object.fromEntries([
                ['value', value]
            ]
            .concat(props.map(prop => {
                const {
                    many,
                    recursive
                } = prop
                const name = typeof prop === 'string' ? prop : prop.name
                const filter = filterAttribute('property', name)
                const subobj = recursive ? obj : prop
                return [camel(name), many ?
                    refines.filter(filter).map(el => getValue(subobj, el)) :
                    getValue(subobj, refines.find(filter))
                ]
            }))
            .concat(attrs.map(attr => [camel(attr), el.getAttribute(attr)])))
    }
    const arr = els.filter(filterAttribute('refines', null))
    const metadata = Object.fromEntries(METADATA.map(obj => {
        const {
            type,
            name,
            many
        } = obj
        const filter = type === 'meta' ?
            el => el.namespaceURI === NS.OPF && el.getAttribute('property') === name :
            el => el.namespaceURI === NS.DC && el.localName === name
        return [camel(name), many ? arr.filter(filter).map(el => getValue(obj, el)) :
            getValue(obj, arr.find(filter))
        ]
    }))

    const getProperties = prefix => Object.fromEntries($$($metadata, 'meta')
        .filter(filterAttribute('property', x => x?.startsWith(prefix)))
        .map(el => [el.getAttribute('property').replace(prefix, ''),
            getElementText(el)
        ]))
    const rendition = getProperties('rendition:')
    const media = getProperties('media:')
    return {
        metadata,
        rendition,
        media
    }
}

const parseNav = (doc, resolve = f => f) => {
    const {
        $,
        $$,
        $$$
    } = childGetter(doc, NS.XHTML)
    const resolveHref = href => href ? decodeURI(resolve(href)) : null
    const parseLI = getType => $li => {
        const $a = $($li, 'a') ?? $($li, 'span')
        const $ol = $($li, 'ol')
        const href = resolveHref($a?.getAttribute('href'))
        const label = getElementText($a) || $a?.getAttribute('title')
        // TODO: get and concat alt/title texts in content
        const result = {
            label,
            href,
            subitems: parseOL($ol)
        }
        if (getType) result.type = $a?.getAttributeNS(NS.EPUB, 'type')?.split(/\s/)
        return result
    }
    const parseOL = ($ol, getType) => $ol ? $$($ol, 'li').map(parseLI(getType)) : null
    const parseNav = ($nav, getType) => parseOL($($nav, 'ol'), getType)

    const $$nav = $$$(doc, 'nav')
    let toc = null,
        pageList = null,
        landmarks = null,
        others = []
    for (const $nav of $$nav) {
        const type = $nav.getAttributeNS(NS.EPUB, 'type')?.split(/\s/) ?? []
        if (type.includes('toc')) toc ??= parseNav($nav)
        else if (type.includes('page-list')) pageList ??= parseNav($nav)
        else if (type.includes('landmarks')) landmarks ??= parseNav($nav, true)
        else others.push({
            label: getElementText($nav.firstElementChild),
            type,
            list: parseNav($nav),
        })
    }
    return {
        toc,
        pageList,
        landmarks,
        others
    }
}

const parseNCX = (doc, resolve = f => f) => {
    const {
        $,
        $$
    } = childGetter(doc, NS.NCX)
    const resolveHref = href => href ? decodeURI(resolve(href)) : null
    const parseItem = el => {
        const $label = $(el, 'navLabel')
        const $content = $(el, 'content')
        const label = getElementText($label)
        const href = resolveHref($content.getAttribute('src'))
        if (el.localName === 'navPoint') {
            const els = $$(el, 'navPoint')
            return {
                label,
                href,
                subitems: els.length ? els.map(parseItem) : null
            }
        }
        return {
            label,
            href
        }
    }
    const parseList = (el, itemName) => $$(el, itemName).map(parseItem)
    const getSingle = (container, itemName) => {
        const $container = $(doc.documentElement, container)
        return $container ? parseList($container, itemName) : null
    }
    return {
        toc: getSingle('navMap', 'navPoint'),
        pageList: getSingle('pageList', 'pageTarget'),
        others: $$(doc.documentElement, 'navList').map(el => ({
            label: getElementText($(el, 'navLabel')),
            list: parseList(el, 'navTarget'),
        })),
    }
}

const parseClock = str => {
    if (!str) return
    const parts = str.split(':').map(x => parseFloat(x))
    if (parts.length === 3) {
        const [h, m, s] = parts
        return h * 60 * 60 + m * 60 + s
    }
    if (parts.length === 2) {
        const [m, s] = parts
        return m * 60 + s
    }
    const [x, unit] = str.split(/(?=[^\d.])/)
    const n = parseFloat(x)
    const f = unit === 'h' ? 60 * 60 :
        unit === 'min' ? 60 :
        unit === 'ms' ? .001 :
        1
    return n * f
}

const parseSMIL = (doc, resolve = f => f) => {
    const {
        $,
        $$$
    } = childGetter(doc, NS.SMIL)
    const resolveHref = href => href ? decodeURI(resolve(href)) : null
    return $$$(doc, 'par').map($par => {
        const id = $($par, 'text')?.getAttribute('src')?.split('#')?.[1]
        const $audio = $($par, 'audio')
        return $audio ? {
            id,
            audio: {
                src: resolveHref($audio.getAttribute('src')),
                clipBegin: parseClock($audio.getAttribute('clipBegin')),
                clipEnd: parseClock($audio.getAttribute('clipEnd')),
            },
        } : {
            id
        }
    })
}

const isUUID = /([0-9a-f]{8})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{12})/

const getUUID = opf => {
    for (const el of opf.getElementsByTagNameNS(NS.DC, 'identifier')) {
        const [id] = getElementText(el).split(':').slice(-1)
        if (isUUID.test(id)) return id
    }
    return ''
}

const getIdentifier = opf => getElementText(
    opf.getElementById(opf.documentElement.getAttribute('unique-identifier')) ??
    opf.getElementsByTagNameNS(NS.DC, 'identifier')[0])

// https://www.w3.org/publishing/epub32/epub-ocf.html#sec-resource-obfuscation
const deobfuscate = async (key, length, blob) => {
    const array = new Uint8Array(await blob.slice(0, length).arrayBuffer())
    length = Math.min(length, array.length)
    for (var i = 0; i < length; i++) array[i] = array[i] ^ key[i % key.length]
    return new Blob([array, blob.slice(length)], {
        type: blob.type
    })
}

const WebCryptoSHA1 = async (str) => {
    const data = new TextEncoder().encode(str)
    const buffer = await globalThis.crypto.subtle.digest('SHA-1', data)
    return new Uint8Array(buffer)
}

const deobfuscators = (sha1 = WebCryptoSHA1) => ({
    'http://www.idpf.org/2008/embedding': {
        key: opf => sha1(getIdentifier(opf)
            // eslint-disable-next-line no-control-regex
            .replaceAll(/[\u0020\u0009\u000d\u000a]/g, '')),
        decode: (key, blob) => deobfuscate(key, 1040, blob),
    },
    'http://ns.adobe.com/pdf/enc#RC': {
        key: opf => {
            const uuid = getUUID(opf).replaceAll('-', '')
            return Uint8Array.from({
                    length: 16
                }, (_, i) =>
                parseInt(uuid.slice(i * 2, i * 2 + 2), 16))
        },
        decode: (key, blob) => deobfuscate(key, 1024, blob),
    },
})

class Encryption {
    #uris = new Map()
    #decoders = new Map()
    #algorithms
    constructor(algorithms) {
        this.#algorithms = algorithms
    }
    async init(encryption, opf, resolveURI) {
        if (!encryption) return
        const data = Array.from(
            encryption.getElementsByTagNameNS(NS.ENC, 'EncryptedData'), el => ({
                algorithm: el.getElementsByTagNameNS(NS.ENC, 'EncryptionMethod')[0]
                    ?.getAttribute('Algorithm'),
                uri: el.getElementsByTagNameNS(NS.ENC, 'CipherReference')[0]
                    ?.getAttribute('URI'),
            }))
        for (const {
                algorithm,
                uri
            }
            of data) {
            const resolvedURI = resolveURI(uri)
            if (!resolvedURI) continue
            if (!this.#decoders.has(algorithm)) {
                const algo = this.#algorithms[algorithm]
                if (!algo) {
                    console.warn('Unknown encryption algorithm')
                    continue
                }
                const key = await algo.key(opf)
                this.#decoders.set(algorithm, blob => algo.decode(key, blob))
            }
            this.#uris.set(resolvedURI, algorithm)
        }
    }
    getDecoder(uri) {
        return this.#decoders.get(this.#uris.get(uri)) ?? (x => x)
    }
}

class Resources {
    constructor({
        opf,
        resolveHref
    }) {
        this.opf = opf
        const {
            $,
            $$,
            $$$
        } = childGetter(opf, NS.OPF)

        const $manifest = $(opf.documentElement, 'manifest')
        const $spine = $(opf.documentElement, 'spine')
        const $$itemref = $$($spine, 'itemref')

        this.manifest = $$($manifest, 'item')
            .map(getAttributes('href', 'id', 'media-type', 'properties', 'media-overlay'))
            .map(item => {
                item.href = resolveHref(item.href)
                item.properties = item.properties?.split(/\s/)
                return item
            })
        this.spine = $$itemref
            .map(getAttributes('idref', 'id', 'linear', 'properties'))
            .map(item => (item.properties = item.properties?.split(/\s/), item))
        this.pageProgressionDirection = $spine
            .getAttribute('page-progression-direction')

        this.navPath = this.getItemByProperty('nav')?.href
        this.ncxPath = (this.getItemByID($spine.getAttribute('toc')) ??
            this.manifest.find(item => item.mediaType === MIME.NCX))?.href

        const $guide = $(opf.documentElement, 'guide')
        if ($guide) this.guide = $$($guide, 'reference')
            .map(getAttributes('type', 'title', 'href'))
            .map(({
                type,
                title,
                href
            }) => ({
                label: title,
                type: type.split(/\s/),
                href: resolveHref(href),
            }))

        this.cover = this.getItemByProperty('cover-image')
            // EPUB 2 compat
            ??
            this.getItemByID($$$(opf, 'meta')
                .find(filterAttribute('name', 'cover'))
                ?.getAttribute('content')) ??
            this.getItemByHref(this.guide
                ?.find(ref => ref.type.includes('cover'))?.href)

        this.cfis = CFI.fromElements($$itemref)
    }
    getItemByID(id) {
        return this.manifest.find(item => item.id === id)
    }
    getItemByHref(href) {
        return this.manifest.find(item => item.href === href)
    }
    getItemByProperty(prop) {
        return this.manifest.find(item => item.properties?.includes(prop))
    }
    resolveCFI(cfi) {
        const parts = CFI.parse(cfi)
        const top = (parts.parent ?? parts).shift()
        let $itemref = CFI.toElement(this.opf, top)
        // make sure it's an idref; if not, try again without the ID assertion
        // mainly because Epub.js used to generate wrong ID assertions
        // https://github.com/futurepress/epub.js/issues/1236
        if ($itemref && $itemref.nodeName !== 'idref') {
            top.at(-1).id = null
            $itemref = CFI.toElement(this.opf, top)
        }
        const idref = $itemref?.getAttribute('idref')
        const index = this.spine.findIndex(item => item.idref === idref)
        const anchor = doc => CFI.toRange(doc, parts)
        return {
            index,
            anchor
        }
    }
}

export class Loader {
    #cache = new Map()
    #children = new Map()
    #refCount = new Map()
    #pending = new Map()
    #transientChildren = new Map()
    #destroyed = false
    allowScript = false
    constructor({
        loadText,
        loadBlob,
        resources,
        replaceText,
        replaceURL
    }) {
        this.loadText = loadText
        this.loadBlob = loadBlob
        this.manifest = resources.manifest
        this.assets = resources.manifest
        this.replaceText = replaceText
        this.replaceURL = replaceURL
        // needed only when replacing in (X)HTML w/o parsing (see below)
        //.filter(({ mediaType }) => ![MIME.XHTML, MIME.HTML].includes(mediaType))
    }
    #assertActive() {
        if (!this.#destroyed) return
        const error = new Error('EPUB resource loader was destroyed')
        error.name = 'AbortError'
        throw error
    }
    #createObjectURL(href, data, type, parent) {
        const url = URL.createObjectURL(new Blob([data], { type }))
        try {
            globalThis.__manabiBlobResourceMap ??= new Map()
            globalThis.__manabiBlobResourceMap.set(url, {
                href,
                type,
                parent: parent ?? null,
                bytes: data?.byteLength ?? data?.length ?? null,
            })
        } catch (_error) {}
        return url
    }
    #forgetURL(url) {
        try {
            globalThis.__manabiBlobResourceMap?.delete?.(url)
        } catch (_error) {}
        if (typeof url === 'string' && url.startsWith('blob:')) URL.revokeObjectURL(url)
    }
    #recordChild(parent, href) {
        if (!parent) return false
        const childList = this.#children.get(parent)
        if (childList?.includes(href)) return false
        if (childList) childList.push(href)
        else this.#children.set(parent, [href])
        return true
    }
    #cacheURL(href, url, parent) {
        this.#cache.set(href, url)
        this.#refCount.set(href, 1)
        this.#recordChild(parent, href)
        return url
    }
    createURL(href, data, type, parent) {
        if (this.#destroyed) return ''
        if (this.#cache.has(href)) return this.ref(href, parent)
        if (data == null) return ''
        return this.#cacheURL(
            href,
            this.#createObjectURL(href, data, type, parent),
            parent,
        )
    }
    #createTransientURL(href, data, type, parent) {
        if (this.#destroyed) return ''
        if (data == null) return ''
        const existing = this.#transientChildren.get(parent)?.get(href)
        if (existing) return existing
        const url = this.#createObjectURL(href, data, type, parent)
        const children = this.#transientChildren.get(parent) ?? new Map()
        children.set(href, url)
        this.#transientChildren.set(parent, children)
        return url
    }
    createDirectURL(href, url, parent) {
        if (this.#destroyed) return ''
        if (this.#cache.has(href)) return this.ref(href, parent)
        return url ? this.#cacheURL(href, url, parent) : ''
    }
    #releaseChildren(parent) {
        const childList = this.#children.get(parent)
        if (childList) {
            this.#children.delete(parent)
            while (childList.length) this.unref(childList.pop())
        }
        const transientChildren = this.#transientChildren.get(parent)
        if (transientChildren) {
            this.#transientChildren.delete(parent)
            for (const url of transientChildren.values()) this.#forgetURL(url)
        }
    }
    ref(href, parent) {
        if (this.#destroyed || !this.#cache.has(href)) return null
        if (!parent || this.#recordChild(parent, href)) {
            this.#refCount.set(href, this.#refCount.get(href) + 1)
        }
        return this.#cache.get(href)
    }
    unref(href) {
        if (!this.#refCount.has(href)) return
        const count = this.#refCount.get(href) - 1
        //console.log(`unreferencing ${href}, now ${count}`)
        if (count < 1) {
            //console.log(`unloading ${href}`)
            const url = this.#cache.get(href)
            this.#forgetURL(url)
            this.#cache.delete(href)
            this.#refCount.delete(href)
            this.#releaseChildren(href)
        } else this.#refCount.set(href, count)
    }
    async #loadUncachedItem(item, parents, parent) {
        if (this.#destroyed) return null
        const { href, mediaType } = item
        const isScript = MIME.JS.test(mediaType)
        const shouldReplace =
            isScript || [MIME.XHTML, MIME.HTML, MIME.CSS, MIME.SVG].includes(mediaType)
        if (shouldReplace) return await this.loadReplaced(item, parents)
        const data = await this.loadBlob(href)
        if (this.#destroyed) return null
        return this.createURL(href, data, mediaType, parent)
    }
    // Load one manifest resource at a time. Concurrent callers share replacement
    // work, then acquire their own top-level or parent-scoped reference.
    async loadItem(item, parents = []) {
        if (this.#destroyed || !item) return null
        const { href, mediaType } = item
        const isScript = MIME.JS.test(mediaType)
        if (isScript && !this.allowScript) return null

        const parent = parents.at(-1)
        // Circular references need a raw URL for the current replacement pass,
        // but they must not enter the href cache or create a ref-count cycle.
        if (parents.includes(href)) {
            const existing = this.#transientChildren.get(parent)?.get(href)
            if (existing) return existing
            return this.#createTransientURL(
                href,
                await this.loadBlob(href),
                mediaType,
                parent,
            )
        }
        if (this.#cache.has(href)) return this.ref(href, parent)

        const pending = this.#pending.get(href)
        if (pending) {
            const result = await pending
            if (this.#destroyed) return null
            return result ? this.ref(href, parent) : result
        }

        // Install ownership before starting user-supplied async loaders so a
        // synchronous re-entry cannot create a second independent acquisition.
        const load = Promise.resolve()
            .then(() => this.#loadUncachedItem(item, parents, parent))
        this.#pending.set(href, load)
        try {
            const result = await load
            // The uncached worker can commit an object URL and resolve its promise
            // before this initiating caller resumes. Teardown queued in between
            // revokes that URL, so the first caller needs the same terminal check
            // already performed by callers that joined `#pending`.
            if (this.#destroyed) return null
            if (!result) this.#releaseChildren(href)
            return result
        } catch (error) {
            // Child assets loaded while replacing this parent are owned by the
            // parent transaction. A failed parent has no later unload callback.
            this.#releaseChildren(href)
            throw error
        } finally {
            if (this.#pending.get(href) === load) this.#pending.delete(href)
        }
    }
    async loadHref(href, base, parents = []) {
        if (this.#destroyed) return null
        const originalHref = String(href ?? '')
        const normalizedHref = trimASCIIURLWhitespace(originalHref)
        if (!normalizedHref) return ''
        if (normalizedHref.startsWith('#')) return normalizedHref
        // A query-only path still targets the current processed document. Keep
        // it local instead of attempting to publish another copy of that item.
        if (normalizedHref.startsWith('?')) return normalizedHref
        if (isExternal(normalizedHref)) {
            // Keep the existing external-resource policy, but let URL parsing
            // perform the same whitespace and escaping normalization the browser
            // applies when the reference is eventually consumed.
            return String(resolveURL(normalizedHref, base))
        }

        const resolved = String(resolveURL(normalizedHref, base))
        const fragmentIndex = resolved.indexOf('#')
        const path = fragmentIndex >= 0 ? resolved.slice(0, fragmentIndex) : resolved
        const fragment = fragmentIndex >= 0 ? resolved.slice(fragmentIndex) : ''
        const normalizedBase = trimASCIIURLWhitespace(base)
        const baseIsPackagePath = !hasURIScheme(normalizedBase)
            && !normalizedBase.startsWith('//')
        if (fragment && baseIsPackagePath) {
            const resolvedBase = String(resolveURL('', normalizedBase))
            const baseFragmentIndex = resolvedBase.indexOf('#')
            const basePath = baseFragmentIndex >= 0
                ? resolvedBase.slice(0, baseFragmentIndex)
                : resolvedBase
            // An explicit current-document reference (for example,
            // `chapter.svg#paint`) must remain local to the processed document.
            // Loading the manifest item again enters the circular-reference path
            // and points at an unprocessed transient copy instead.
            if (path === basePath) return fragment
        }

        const item = this.manifest.find(item => item.href === path)
        // Blob-backed documents cannot safely resolve scheme-relative URLs,
        // or relative URLs whose source stylesheet/document itself is remote.
        // Preserve package-relative fallback text for undeclared local assets,
        // but return the already-resolved absolute URL for remote resources.
        if (!item) return isExternal(resolved) ? resolved : originalHref
        const loaded = await this.loadItem(item, parents.concat(base))
        return loaded ? `${loaded}${fragment}` : originalHref
    }
    async #replaceSrcset(value, href, parents) {
        const candidates = parseSrcsetCandidates(value)
        if (!candidates.length) return value
        const rewritten = []
        for (const { url, descriptor } of candidates) {
            const loaded = await this.loadHref(url, href, parents)
            rewritten.push(descriptor ? `${loaded} ${descriptor}` : loaded)
        }
        return rewritten.join(', ')
    }
    async loadReplaced(item, parents = []) {
        if (this.#destroyed) return null
        const {
            href,
            mediaType
        } = item
        const parent = parents.at(-1)
        if (this.replaceURL && [MIME.XHTML, MIME.HTML].includes(mediaType)) {
            const directURL = await this.replaceURL(href, mediaType)
            if (this.#destroyed) return null
            if (!directURL) {
                const error = new Error(`Direct processed section URL required for ${href}`)
                throw error
            }
            return this.createDirectURL(href, directURL, parent)
        }
        const str = await this.loadText(href)
        if (this.#destroyed) return null
        if (str == null) return null

        // note that one can also just use `replaceString` for everything:
        // ```
        // const replaced = await this.replaceString(str, href, parents)
        // return this.createURL(href, replaced, mediaType, parent)
        // ```
        // which is basically what Epub.js does, which is simpler, but will
        // break things like iframes (because you don't want to replace links)
        // or text that just happen to be paths

        // Call replaceText with the original, unmodified text BEFORE any DOM parsing/rewriting
        let replacedStr = str
        if (this.replaceText) {
            replacedStr = await this.replaceText(href, str, mediaType)
            if (this.#destroyed) return null
        }

        if (replacedStr == null) {
            return null
        }

        // parse and replace in HTML
        if ([MIME.XHTML, MIME.HTML, MIME.SVG].includes(mediaType)) {
            let effectiveMediaType = mediaType
            let doc = new DOMParser().parseFromString(replacedStr, effectiveMediaType)
            // change to HTML if it's not valid XHTML
            if (effectiveMediaType === MIME.XHTML && doc.querySelector('parsererror')) {
                console.warn(doc.querySelector('parsererror').innerText)
                effectiveMediaType = MIME.HTML
                doc = new DOMParser().parseFromString(replacedStr, effectiveMediaType)
            }
            // Replace resource URLs in processing instructions such as
            // xml-stylesheet. Comments or a doctype may legally precede the PI,
            // so inspect all document children rather than only a leading run.
            if ([MIME.XHTML, MIME.SVG].includes(effectiveMediaType)) {
                for (const child of Array.from(doc.childNodes ?? [])) {
                    if (!(child instanceof ProcessingInstruction)
                        || child.target?.toLowerCase?.() !== 'xml-stylesheet'
                        || !child.data) continue
                    const replacedData = await replaceSeries(
                        child.data,
                        /(\bhref\s*=\s*['"])([^'"]*)(['"])/i,
                        (_, p1, p2, p3) => this.loadHref(p2, href, parents)
                            .then(value => `${p1}${value}${p3}`),
                    )
                    child.replaceWith(doc.createProcessingInstruction(
                        child.target,
                        replacedData,
                    ))
                }
            }
            // Replace stylesheet links plus resource-bearing SVG2 `href`
            // attributes. Navigation anchors remain publication links and must
            // continue through the reader's normal link handling. Local SVG
            // fragment references are preserved by `loadHref`.
            const replace = async (el, attr) => el.setAttribute(attr,
                await this.loadHref(el.getAttribute(attr), href, parents))
            const replaceSrcset = async (el, attr) => el.setAttribute(attr,
                await this.#replaceSrcset(el.getAttribute(attr), href, parents))
            const hrefElements = new Set(
                Array.from(doc.querySelectorAll('link[href]'))
                    .filter(linkElementLoadsResource)
            )
            for (const el of doc.querySelectorAll('[href]')) {
                const isSVGResource = el.namespaceURI === NS.SVG
                    && el.localName?.toLowerCase?.() !== 'a'
                if (isSVGResource) hrefElements.add(el)
            }
            for (const el of hrefElements) await replace(el, 'href')
            for (const el of doc.querySelectorAll('[src]')) await replace(el, 'src')
            for (const el of doc.querySelectorAll('[srcset]')) {
                await replaceSrcset(el, 'srcset')
            }
            for (const el of doc.querySelectorAll('[imagesrcset]')) {
                await replaceSrcset(el, 'imagesrcset')
            }
            for (const el of doc.querySelectorAll('[poster]')) await replace(el, 'poster')
            for (const el of doc.querySelectorAll('object[data]')) await replace(el, 'data')
            const replaceCSSURLs = value => rewriteCSS(
                value,
                url => this.loadHref(url, href, parents),
                code => code,
            )
            // Consolidate less-common package resource attributes and inline
            // CSS into one namespace-safe DOM pass. `getElementsByTagName('style')`
            // matches qualified names, so it misses valid prefixed XML elements
            // such as `<svg:style>` and `<html:style>`.
            const allElements = Array.from(doc.getElementsByTagName('*'))
            for (const el of allElements) {
                const localName = el.localName?.toLowerCase?.()
                if (
                    el.namespaceURI === NS.XHTML
                    && el.hasAttribute('background')
                ) {
                    await replace(el, 'background')
                }
                const isSVG = el.namespaceURI === NS.SVG
                if (isSVG) {
                    for (const attribute of SVG_CSS_RESOURCE_ATTRIBUTES) {
                        if (!el.hasAttribute(attribute)) continue
                        el.setAttribute(
                            attribute,
                            await replaceCSSURLs(el.getAttribute(attribute)),
                        )
                    }
                }
                if (
                    localName !== 'a'
                    && !el.hasAttribute('href')
                    && el.hasAttributeNS(NS.XLINK, 'href')
                ) {
                    el.setAttributeNS(
                        NS.XLINK,
                        'href',
                        await this.loadHref(
                            el.getAttributeNS(NS.XLINK, 'href'),
                            href,
                            parents,
                        ),
                    )
                }
                if (
                    localName === 'style'
                    && (!el.namespaceURI || el.namespaceURI === NS.XHTML || isSVG)
                    && el.textContent
                ) {
                    el.textContent = await this.replaceCSS(
                        el.textContent,
                        href,
                        parents,
                    )
                }
                if (el.hasAttribute('style')) {
                    el.setAttribute(
                        'style',
                        await this.replaceCSS(el.getAttribute('style'), href, parents),
                    )
                }
            }
            // TODO: replace inline scripts? probably not worth the trouble
            const textResult = new XMLSerializer().serializeToString(doc)
            const url = this.createURL(href, textResult, effectiveMediaType, parent)
            if (url && effectiveMediaType !== mediaType) item.mediaType = effectiveMediaType
            return url
        }

        const result = mediaType === MIME.CSS ?
            await this.replaceCSS(replacedStr, href, parents) :
            await this.replaceString(replacedStr, href, parents)
        return this.createURL(href, result, mediaType, parent)
    }
    async replaceCSS(str, href, parents = []) {
        const w = window?.innerWidth ?? 800
        const h = window?.innerHeight ?? 600
        return rewriteCSS(
            str,
            url => this.loadHref(url, href, parents),
            code => code
                // Unprefix declaration names without mutating selectors or values.
                .replace(/(^|[;{(])(\s*)-epub-(?=[-a-z0-9_]+\s*:)/gi, '$1$2')
                // Replace viewport dimensions without matching identifier suffixes.
                .replace(
                    /(^|[^a-z0-9_.-])(-?\d*\.?\d+)(vw|vh)\b/gi,
                    (_, prefix, value, unit) => {
                        const basis = unit.toLowerCase() === 'vw' ? w : h
                        return `${prefix}${parseFloat(value) * basis / 100}px`
                    },
                )
                // `page-break-*` declaration names are unsupported in columns.
                .replace(
                    /(^|[;{(])(\s*)page-break-(after|before|inside)(?=\s*:)/gi,
                    (_, prefix, whitespace, name) =>
                        `${prefix}${whitespace}-webkit-column-break-${name}`,
                ),
        )
    }
    // find & replace all possible relative paths for all assets without parsing
    replaceString(str, href, parents = []) {
        const assetMap = new Map()
        for (const asset of this.assets) {
            // do not replace references to the file itself
            if (asset.href === href) continue
            // href was decoded and resolved when parsing the manifest
            const relative = pathRelative(pathDirname(href), asset.href)
            const relativeEnc = encodeURI(relative)
            const explicitRelative = relative ? `./${relative}` : relative
            const explicitRelativeEnc = encodeURI(explicitRelative)
            const rootRelative = '/' + asset.href
            const rootRelativeEnc = encodeURI(rootRelative)
            for (const url of new Set([
                relative,
                relativeEnc,
                explicitRelative,
                explicitRelativeEnc,
                rootRelative,
                rootRelativeEnc,
            ])) if (url && !assetMap.has(url)) assetMap.set(url, asset)
        }
        if (!assetMap.size) return str
        // A manifest path may prefix another manifest path. Match the longest
        // exact candidate first so `image.png` cannot corrupt `image.png.map`.
        const urls = [...assetMap.keys()].sort((lhs, rhs) => rhs.length - lhs.length)
        const regex = new RegExp(
            `(${urls.map(regexEscape).join('|')})${RAW_RESOURCE_SUFFIX}`,
            'g',
        )
        return replaceSeries(
            str,
            regex,
            async (match, reference, fragment, offset, source) => {
                if (!rawResourceReferenceIsComplete(source, offset, match.length)) {
                    return match
                }
                const asset = assetMap.get(reference)
                if (!asset) return match
                const loaded = await this.loadItem(asset, parents.concat(href))
                return loaded ? `${loaded}${fragment ?? ''}` : match
            },
        )
    }
    unloadItem(item) {
        this.unref(item?.href)
    }
    destroy() {
        if (this.#destroyed) return false
        this.#destroyed = true
        const replacementOwners = new Set([this.replaceText, this.replaceURL].filter(Boolean))
        this.replaceText = null
        this.replaceURL = null
        for (const owner of replacementOwners) {
            try {
                owner.destroy?.()
            } catch (_error) {}
        }
        for (const url of this.#cache.values()) this.#forgetURL(url)
        for (const children of this.#transientChildren.values()) {
            for (const url of children.values()) this.#forgetURL(url)
        }
        this.#cache.clear()
        this.#children.clear()
        this.#refCount.clear()
        this.#pending.clear()
        this.#transientChildren.clear()
        this.manifest = []
        this.assets = []
        return true
    }
}

const getHTMLFragment = (doc, id) => doc.getElementById(id) ??
    doc.querySelector(`[name="${CSS.escape(id)}"]`)

const getPageSpread = properties => {
    for (const p of properties) {
        if (p === 'page-spread-left' || p === 'rendition:page-spread-left')
            return 'left'
        if (p === 'page-spread-right' || p === 'rendition:page-spread-right')
            return 'right'
        if (p === 'rendition:page-spread-center') return 'center'
    }
}

export class EPUB {
    parser = new DOMParser()
    #loader
    #sourceDestroy
    #destroyed = false
    #encryption
    constructor({
        loadText,
        loadBlob,
        getSize,
        replaceText,
        replaceURL,
        sha1,
        destroy: destroySource,
    }) {
        this.loadText = loadText
        this.loadBlob = loadBlob
        this.getSize = getSize
        this.replaceText = replaceText
        this.replaceURL = replaceURL
        this.#sourceDestroy = typeof destroySource === 'function' ? destroySource : null
        this.#encryption = new Encryption(deobfuscators(sha1))
    }
    #assertActive() {
        if (!this.#destroyed) return
        const error = new Error('EPUB has been destroyed')
        error.name = 'AbortError'
        throw error
    }
    async #loadXML(uri) {
        this.#assertActive()
        const str = await this.loadText(uri)
        this.#assertActive()
        if (!str) return null
        const doc = this.parser.parseFromString(str, MIME.XML)
        if (doc.querySelector('parsererror'))
            throw new Error(`XML parsing error: ${uri}
${doc.querySelector('parsererror').innerText}`)
        return doc
    }
    async init() {
        this.#assertActive()
        const $container = await this.#loadXML('META-INF/container.xml')
        if (!$container) throw new Error('Failed to load container file')

        const opfs = Array.from(
                $container.getElementsByTagNameNS(NS.CONTAINER, 'rootfile'),
                getAttributes('full-path', 'media-type'))
            .filter(file => file.mediaType === 'application/oebps-package+xml')

        if (!opfs.length) throw new Error('No package document defined in container')
        const opfPath = resolvePackageEntryPath(opfs[0].fullPath)
        if (!opfPath) throw new Error('Invalid package document path in container')
        const opf = await this.#loadXML(opfPath)
        if (!opf) throw new Error('Failed to load package document')

        const $encryption = await this.#loadXML('META-INF/encryption.xml')
        await this.#encryption.init(
            $encryption,
            opf,
            resolvePackageEntryPath,
        )
        this.#assertActive()

        this.resources = new Resources({
            opf,
            resolveHref: url => resolveURL(url, opfPath),
        })
        this.#loader = new Loader({
            loadText: this.loadText,
            loadBlob: uri => Promise.resolve(this.loadBlob(uri))
                .then(this.#encryption.getDecoder(uri)),
            resources: this.resources,
            replaceText: this.replaceText,
            replaceURL: this.replaceURL,
        })
        this.sections = this.resources.spine.map((spineItem, index) => {
            const {
                idref,
                linear,
                properties = []
            } = spineItem
            const item = this.resources.getItemByID(idref)
            if (!item) {
                console.warn(`Could not find item with ID "${idref}" in manifest`)
                return null
            }
            return {
                id: this.resources.getItemByID(idref)?.href,
                load: () => this.#loader.loadItem(item),
                unload: () => this.#loader.unloadItem(item),
                createDocument: () => this.loadDocument(item),
                size: this.getSize(item.href),
                cfi: this.resources.cfis[index],
                linear,
                pageSpread: getPageSpread(properties),
                resolveHref: href => resolveURL(href, item.href),
                loadMediaOverlay: () => this.loadMediaOverlay(item),
            }
        }).filter(s => s)

        const {
            navPath,
            ncxPath
        } = this.resources
        if (navPath) try {
            const resolve = url => resolveURL(url, navPath)
            const nav = parseNav(await this.#loadXML(navPath), resolve)
            this.toc = nav.toc
            this.pageList = nav.pageList
            this.landmarks = nav.landmarks
        } catch (e) {
            console.warn(e)
        }
        if (!this.toc && ncxPath) try {
            const resolve = url => resolveURL(url, ncxPath)
            const ncx = parseNCX(await this.#loadXML(ncxPath), resolve)
            this.toc = ncx.toc
            this.pageList = ncx.pageList
        } catch (e) {
            console.warn(e)
        }
        this.landmarks ??= this.resources.guide

        const {
            metadata,
            rendition,
            media
        } = getMetadata(opf)
        this.rendition = rendition
        this.media = media
        media.duration = parseClock(media.duration)
        this.dir = this.resources.pageProgressionDirection

        this.rawMetadata = metadata // useful for debugging, i guess
        const title = metadata?.title?.[0]
        this.metadata = {
            title: title?.value,
            subtitle: metadata?.title?.find(x => x.titleType === 'subtitle')?.value,
            sortAs: title?.fileAs,
            language: metadata?.language,
            identifier: getIdentifier(opf),
            description: metadata?.description?.value,
            publisher: metadata?.publisher?.value,
            published: metadata?.date,
            modified: metadata?.dctermsModified,
            subject: metadata?.subject
                ?.filter(({
                    value,
                    code
                }) => value || code)
                ?.map(({
                    value,
                    code,
                    scheme
                }) => ({
                    name: value,
                    code,
                    scheme
                })),
            rights: metadata?.rights?.value,
        }
        const relators = {
            art: 'artist',
            aut: 'author',
            bkp: 'producer',
            clr: 'colorist',
            edt: 'editor',
            ill: 'illustrator',
            trl: 'translator',
            pbl: 'publisher',
        }
        const mapContributor = defaultKey => obj => {
            const keys = [...new Set(obj.role?.map(({
                    value,
                    scheme
                }) =>
                (!scheme || scheme === 'marc:relators' ? relators[value] : null) ??
                defaultKey))]
            const value = {
                name: obj.value,
                sortAs: obj.fileAs
            }
            return [keys?.length ? keys : [defaultKey], value]
        }
        metadata?.creator?.map(mapContributor('author'))
            ?.concat(metadata?.contributor?.map?.(mapContributor('contributor')))
            ?.forEach(([keys, value]) => keys.forEach(key => {
                if (this.metadata[key]) this.metadata[key].push(value)
                else this.metadata[key] = [value]
            }))

        this.#assertActive()
        return this
    }
    async loadDocument(item) {
        this.#assertActive()
        const str = await this.loadText(item.href)
        this.#assertActive()
        return this.parser.parseFromString(str, item.mediaType)
    }
    async loadMediaOverlay(item) {
        const id = item.mediaOverlay
        if (!id) return null
        const media = this.resources.getItemByID(id)
        const doc = await this.#loadXML(media.href)
        const parsed = parseSMIL(doc, url => resolveURL(url, media.href))
        return parsed
    }
    resolveCFI(cfi) {
        return this.resources.resolveCFI(cfi)
    }
    resolveHref(href) {
        const [path, hash] = href.split('#')
        const item = this.resources.getItemByHref(decodeURI(path))
        if (!item) return null
        const index = this.resources.spine.findIndex(({
            idref
        }) => idref === item.id)
        const anchor = hash ? doc => getHTMLFragment(doc, hash) : () => 0
        return {
            index,
            anchor
        }
    }
    splitTOCHref(href) {
        return href?.split('#') ?? []
    }
    getTOCFragment(doc, id) {
        return doc.getElementById(id) ??
            doc.querySelector(`[name="${CSS.escape(id)}"]`)
    }
    isExternal(uri) {
        return isExternal(uri)
    }
    async getCover() {
        this.#assertActive()
        const cover = this.resources?.cover
        if (!cover?.href) return null
        const data = await this.loadBlob(cover.href)
        this.#assertActive()
        return new Blob([data], { type: cover.mediaType })
    }
    async getCalibreBookmarks() {
        this.#assertActive()
        const txt = await this.loadText('META-INF/calibre_bookmarks.txt')
        this.#assertActive()
        const magic = 'encoding=json+base64:'
        if (txt?.startsWith(magic)) {
            const json = atob(txt.slice(magic.length))
            return JSON.parse(json)
        }
    }
    destroy() {
        if (this.#destroyed) return false
        this.#destroyed = true
        const loader = this.#loader
        this.#loader = null
        try {
            loader?.destroy?.()
        } catch (_error) {}
        const destroySource = this.#sourceDestroy
        this.#sourceDestroy = null
        try {
            const result = destroySource?.()
            Promise.resolve(result).catch(() => {})
        } catch (_error) {}
        return true
    }
}
